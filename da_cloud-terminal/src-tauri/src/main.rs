// ╔══════════════════════════════════════════════════════════════════╗
// ║ Cloud Terminal — Tauri (Rust) main process.                       ║
// ║                                                                    ║
// ║ Port of the former Electron main.ts + pty-server.js. Tauri gives   ║
// ║ us a native system-webview panel + native tray, and portable-pty   ║
// ║ gives us PTYs IN-PROCESS — so the separate node pty-server helper   ║
// ║ (which existed only to dodge node-pty's Electron-ABI mismatch) is   ║
// ║ GONE. One binary, no bundled Chromium, no bundled Node.             ║
// ║                                                                    ║
// ║ Everything data-driven from src/data/profile-*.json (unchanged).   ║
// ║ Paths injected via env (CT_*) by the Nix wrapper, same as before.  ║
// ╚══════════════════════════════════════════════════════════════════╝
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use serde::Deserialize;
use serde_json::Value;
use tauri::{
    menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder},
    tray::{TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder,
};

// ── Env config (mirrors main.ts) ─────────────────────────────────────
fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

// The app itself is launched with a nix WebKit LD_LIBRARY_PATH so its webview
// resolves. ANY system tool we spawn (journalctl, ssh, docker, findmnt, git,
// curl, kill, …) must NOT inherit it — otherwise it loads nix glibc/webkit libs
// off that path and fails silently (empty output). Clear it for every spawn.
fn sys_cmd(prog: &str) -> std::process::Command {
    let mut c = std::process::Command::new(prog);
    c.env("LD_LIBRARY_PATH", "");
    c
}

// Send a signal directly via the libc kill(2) syscall — NOT `Command::new
// ("kill")`. On this box (and likely others) `kill` is ONLY a shell builtin
// with no standalone executable on PATH, so every previous Command::new
// ("kill") spawn (proc_kill, zombie_reap, psi_reclaim) silently failed all
// session: Command needs a real file to exec, it can't invoke a builtin.
// linking libc directly removes the PATH dependency entirely — this is a
// stable, always-available syscall, no new crate needed.
unsafe extern "C" { fn kill(pid: i32, sig: i32) -> i32; }
const SIGTERM: i32 = 15;
const SIGKILL: i32 = 9;
const SIGCHLD: i32 = 17;
fn send_signal(pid: u32, sig: i32) -> bool { unsafe { kill(pid as i32, sig) == 0 } }

// SSH with a PERSISTENT connection mux (ControlMaster): the first call opens a
// master socket, subsequent calls (probe / docker stats / logs) reuse it —
// no repeated TCP+crypto handshake over the WireGuard mesh. ControlPersist
// keeps the master alive between refreshes.
fn ssh_cmd(alias: &str) -> std::process::Command {
    let cm = format!("{}/.ssh/cm-%C", env_or("HOME", "/tmp"));
    let mut c = sys_cmd("ssh");
    c.args([
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=7",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ControlMaster=auto",
        "-o", &format!("ControlPath={cm}"),
        "-o", "ControlPersist=180s",
        alias,
    ]);
    c
}

// ── PTY broker ───────────────────────────────────────────────────────
// One session per (window_label, tab_id). Holds the writer + master so we
// can send keystrokes / resize / kill. The reader runs on its own thread
// and emits "pty-data" events back to the ORIGINATING window.
struct PtySession {
    writer: Box<dyn Write + Send>,
    master: Box<dyn portable_pty::MasterPty + Send>,
}

#[derive(Default)]
struct PtyManager {
    sessions: Mutex<HashMap<String, PtySession>>,
}

fn pk(window: &str, id: i64) -> String {
    format!("{window}:{id}")
}

// ── App-wide state ───────────────────────────────────────────────────
struct AppState {
    profiles: Vec<Value>,
    ptys: Arc<PtyManager>,
    xdg: String,
    shell: String,
    // System-monitor sources: persisted so CPU% and net rates are deltas
    // between polls (the DTK-profile dashboard invokes sys_stats on a timer).
    sys: Mutex<sysinfo::System>,
    nets: Mutex<sysinfo::Networks>,
}

// ── /proc + /sys readers for glances-grade extras (Linux) ────────────
// Pressure Stall Information: /proc/pressure/{cpu,io,memory}. Each file has
// a "some" line (and "full" for io/memory) with avg10/avg60/avg300 = % of
// time tasks stalled on that resource. System-wide (kernel has no per-core PSI).
fn read_psi(kind: &str) -> Value {
    let mut out = serde_json::Map::new();
    if let Ok(txt) = std::fs::read_to_string(format!("/proc/pressure/{kind}")) {
        for line in txt.lines() {
            let mut it = line.split_whitespace();
            let tag = it.next().unwrap_or("");        // "some" | "full"
            let mut o = serde_json::Map::new();
            for kv in it {
                if let Some((k, v)) = kv.split_once('=') {
                    if let Ok(f) = v.parse::<f64>() { o.insert(k.to_string(), serde_json::json!(f)); }
                }
            }
            if !tag.is_empty() { out.insert(tag.to_string(), Value::Object(o)); }
        }
    }
    Value::Object(out)
}

// /proc/swaps: active swap devices (partition / file / zram). Size/Used in KB.
fn read_swaps() -> Vec<Value> {
    let mut v = vec![];
    if let Ok(txt) = std::fs::read_to_string("/proc/swaps") {
        for line in txt.lines().skip(1) {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() >= 5 {
                v.push(serde_json::json!({
                    "name": f[0], "kind": f[1],
                    "size": f[2].parse::<u64>().unwrap_or(0) * 1024,
                    "used": f[3].parse::<u64>().unwrap_or(0) * 1024,
                    "prio": f[4],
                }));
            }
        }
    }
    v
}

fn sysfs_str(base: &std::path::Path, f: &str) -> Option<String> {
    std::fs::read_to_string(base.join(f)).ok().map(|s| s.trim().to_string())
}
fn sysfs_num(base: &std::path::Path, f: &str) -> u64 {
    sysfs_str(base, f).and_then(|s| s.parse().ok()).unwrap_or(0)
}

// zram compression stats: /sys/block/zram*/{disksize,mm_stat}.
// mm_stat = orig_data_size compr_data_size mem_used_total ...
fn read_zram() -> Vec<Value> {
    let mut v = vec![];
    if let Ok(rd) = std::fs::read_dir("/sys/block") {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if !name.starts_with("zram") { continue; }
            let base = e.path();
            let disksize = sysfs_num(&base, "disksize");
            if disksize == 0 { continue; }
            let n: Vec<u64> = std::fs::read_to_string(base.join("mm_stat"))
                .unwrap_or_default().split_whitespace().filter_map(|x| x.parse().ok()).collect();
            let (orig, compr, used) = (n.first().copied().unwrap_or(0), n.get(1).copied().unwrap_or(0), n.get(2).copied().unwrap_or(0));
            v.push(serde_json::json!({
                "name": name, "disksize": disksize, "orig": orig, "compr": compr, "used": used,
                "ratio": if compr > 0 { orig as f64 / compr as f64 } else { 0.0 },
            }));
        }
    }
    v
}

// Battery + AC: /sys/class/power_supply/*. Prefers energy_* (µWh)/power_now
// (µW); falls back to charge_*(µAh)×voltage. Estimates time-to-empty/full.
fn read_power() -> Value {
    let mut batteries = vec![];
    let mut ac_online = false;
    if let Ok(rd) = std::fs::read_dir("/sys/class/power_supply") {
        for e in rd.flatten() {
            let base = e.path();
            let typ = sysfs_str(&base, "type").unwrap_or_default();
            if typ == "Mains" || typ == "USB" {
                if sysfs_num(&base, "online") == 1 { ac_online = true; }
                continue;
            }
            if typ != "Battery" { continue; }
            let status = sysfs_str(&base, "status").unwrap_or_default();
            let capacity = sysfs_num(&base, "capacity");
            let (mut e_now, mut e_full, mut p_now) =
                (sysfs_num(&base, "energy_now"), sysfs_num(&base, "energy_full"), sysfs_num(&base, "power_now"));
            if e_full == 0 {
                let volt = sysfs_num(&base, "voltage_now").max(1); // µV
                e_now = sysfs_num(&base, "charge_now") / 1000 * volt / 1_000_000;
                e_full = sysfs_num(&base, "charge_full") / 1000 * volt / 1_000_000;
                p_now = sysfs_num(&base, "current_now") / 1000 * volt / 1_000_000;
            }
            let hours = if p_now > 0 {
                if status == "Charging" { e_full.saturating_sub(e_now) as f64 / p_now as f64 }
                else { e_now as f64 / p_now as f64 }
            } else { 0.0 };
            batteries.push(serde_json::json!({
                "name": e.file_name().to_string_lossy(), "status": status, "capacity": capacity,
                "watts": p_now as f64 / 1_000_000.0,           // W (draw or charge)
                "energy": e_now as f64 / 1_000_000.0,          // Wh
                "energy_full": e_full as f64 / 1_000_000.0,    // Wh
                "secs": (hours * 3600.0) as u64,
            }));
        }
    }
    serde_json::json!({ "ac": ac_online, "batteries": batteries })
}

// Per-process PSI: the kernel only exposes pressure per cgroup, so a process's
// PSI is the pressure of the cgroup it lives in (its systemd scope/service).
// Reads /proc/<pid>/cgroup → the v2 path → cpu/io/memory.pressure "some avg10".
// Cached by cgroup path (many processes share one cgroup) to stay cheap.
fn proc_cgroup_psi(pid: u32, cache: &mut HashMap<String, Value>) -> Value {
    let cg = match std::fs::read_to_string(format!("/proc/{pid}/cgroup")) {
        Ok(c) => c, Err(_) => return Value::Null,
    };
    // cgroup v2: a single "0::/system.slice/…" line.
    let path = cg.lines().find_map(|l| l.strip_prefix("0::")).unwrap_or("").trim().to_string();
    if path.is_empty() { return Value::Null; }
    if let Some(v) = cache.get(&path) { return v.clone(); }
    let base = format!("/sys/fs/cgroup{path}");
    let some_avg10 = |file: &str| -> f64 {
        std::fs::read_to_string(format!("{base}/{file}")).ok()
            .and_then(|t| t.lines().find(|l| l.starts_with("some")).map(|l| l.to_string()))
            .and_then(|l| l.split_whitespace().find_map(|kv| kv.strip_prefix("avg10=").and_then(|v| v.parse::<f64>().ok())))
            .unwrap_or(0.0)
    };
    let v = serde_json::json!({
        "cpu": some_avg10("cpu.pressure"),
        "io":  some_avg10("io.pressure"),
        "mem": some_avg10("memory.pressure"),
    });
    cache.insert(path, v.clone());
    v
}

fn enrich_psi(list: &mut [Value], cache: &mut HashMap<String, Value>) {
    for row in list.iter_mut() {
        if let Some(pid) = row.get("pid").and_then(|v| v.as_u64()) {
            let p = proc_cgroup_psi(pid as u32, cache);
            if let Some(o) = row.as_object_mut() { o.insert("psi".into(), p); }
        }
    }
}

// ── System monitor snapshot (btop-graphs + glances-data dashboard) ────
// Rich enough to drive a btop+glances clone: CPU (aggregate+per-core+model+
// freq), load, mem breakdown (used/avail/cached/free/swap), temps, disks,
// per-iface net rates, and a full process table (pid/user/cpu%/mem%/status/
// command) reported both top-by-CPU and top-by-MEM, plus process counts.
#[tauri::command]
fn sys_stats(state: tauri::State<AppState>) -> Value {
    use std::cmp::Ordering::Equal;
    let mut sys = state.sys.lock().unwrap();
    sys.refresh_all(); // cpu usage + memory + processes (delta vs previous poll)

    let cpus = sys.cpus();
    let cores: Vec<f32> = cpus.iter().map(|c| c.cpu_usage()).collect();
    let cores_freq: Vec<u64> = cpus.iter().map(|c| c.frequency()).collect(); // per-core MHz
    let cpu_name = cpus.first().map(|c| c.brand().trim().to_string()).unwrap_or_default();
    let cpu_freq = cpus.first().map(|c| c.frequency()).unwrap_or(0); // MHz
    let la = sysinfo::System::load_average();

    // Precise Buffers/Cached from /proc/meminfo (sysinfo folds these into
    // "available"); glances shows them explicitly. kB → bytes.
    let (mut buffers, mut cached) = (0u64, 0u64);
    if let Ok(mi) = std::fs::read_to_string("/proc/meminfo") {
        for line in mi.lines() {
            let mut it = line.split_whitespace();
            let (key, val) = (it.next().unwrap_or(""), it.next().and_then(|v| v.parse::<u64>().ok()).unwrap_or(0));
            match key {
                "Buffers:" => buffers = val * 1024,
                "Cached:" | "SReclaimable:" => cached += val * 1024,
                _ => {}
            }
        }
    }

    // Users: resolve uid → name for the process table (glances shows user).
    let users = sysinfo::Users::new_with_refreshed_list();

    let mut nets = state.nets.lock().unwrap();
    nets.refresh();
    let net: Vec<Value> = nets
        .iter()
        .filter(|(n, _)| *n != "lo")
        .map(|(n, d)| serde_json::json!({
            "name": n, "rx": d.received(), "tx": d.transmitted(),
            "rx_total": d.total_received(), "tx_total": d.total_transmitted(),
            "rx_pkts": d.packets_received(), "tx_pkts": d.packets_transmitted(),
            "rx_err": d.errors_on_received(), "tx_err": d.errors_on_transmitted(),
            "mac": d.mac_address().to_string(),
            "ips": d.ip_networks().iter().map(|ip| format!("{}/{}", ip.addr, ip.prefix)).collect::<Vec<_>>(),
        }))
        .collect();

    let disks = sysinfo::Disks::new_with_refreshed_list();
    let disk: Vec<Value> = disks
        .iter()
        .map(|d| serde_json::json!({
            "name": d.name().to_string_lossy(),
            "mount": d.mount_point().to_string_lossy(),
            "fs": d.file_system().to_string_lossy(),
            "total": d.total_space(),
            "avail": d.available_space(),
        }))
        .collect();

    // Temperatures (btop's temp readouts): CPU package, cores, drives, etc.
    let comps = sysinfo::Components::new_with_refreshed_list();
    let temps: Vec<Value> = comps
        .iter()
        .map(|c| serde_json::json!({
            "label": c.label(),
            "temp": c.temperature(),
            "high": c.max(),
            "crit": c.critical(),
        }))
        .collect();

    // Process table. total_mem drives MEM%. We report three pre-sorted views
    // (by CPU / MEM / IO) each with: short name + full command, io rate, run
    // time, ppid and an ancestry chain (name of each parent up to init) — the
    // glances hierarchy column (User ▸ parent ▸ … or User ▸ zombie).
    let total_mem = sys.total_memory().max(1);
    let mut running = 0u32;
    let (mut dio_r, mut dio_w) = (0u64, 0u64);
    // pid → (short name, parent pid) for ancestry walking.
    let pmap: HashMap<u32, (String, Option<u32>)> = sys.processes().iter()
        .map(|(pid, p)| (pid.as_u32(), (p.name().to_string_lossy().into_owned(), p.parent().map(|pp| pp.as_u32()))))
        .collect();
    struct P { cpu: f32, mem: u64, vms: u64, io: u64, io_rt: u64, io_wt: u64, threads: usize,
        pid: u32, ppid: u32, user: String, status: String, time: u64, start: u64,
        name: String, cmd: String, exe: String, cwd: String, anc: Vec<String> }
    let mut rows: Vec<P> = sys
        .processes()
        .iter()
        // Drop threads (JIT workers etc.): sysinfo lists each thread as a task
        // with its own TID, the thread's comm as name ("JITWorker"), and the
        // parent process's RSS — cluttering the list with dozens of identical
        // rows. Only real processes (thread group leaders) belong here.
        .filter(|(_, p)| p.thread_kind().is_none())
        .map(|(pid, p)| {
            let st = p.status().to_string();
            if st == "Run" || st == "Runnable" { running += 1; }
            let du = p.disk_usage();
            dio_r += du.read_bytes; dio_w += du.written_bytes;
            let user = p
                .user_id()
                .and_then(|uid| users.get_user_by_id(uid))
                .map(|u| u.name().to_string())
                .unwrap_or_default();
            let name = p.name().to_string_lossy().into_owned();
            let cmd = {
                let c = p.cmd();
                if c.is_empty() { name.clone() }
                else { c.iter().map(|s| s.to_string_lossy().into_owned()).collect::<Vec<String>>().join(" ") }
            };
            // ancestry chain root→parent (skip self), capped at 4 hops.
            let ppid = p.parent().map(|pp| pp.as_u32()).unwrap_or(0);
            let mut anc = Vec::new();
            let mut cur = p.parent().map(|pp| pp.as_u32());
            let mut guard = 0;
            while let Some(cp) = cur { if cp == 0 || guard >= 6 { break }
                if let Some((nm, par)) = pmap.get(&cp) { anc.push(nm.clone()); cur = *par; } else { break }
                guard += 1;
            }
            anc.reverse();
            P {
                cpu: p.cpu_usage(), mem: p.memory(), vms: p.virtual_memory(),
                io: du.read_bytes + du.written_bytes, io_rt: du.total_read_bytes, io_wt: du.total_written_bytes,
                threads: p.tasks().map(|t| t.len()).unwrap_or(0),
                pid: pid.as_u32(), ppid, user, status: st, time: p.run_time(), start: p.start_time(),
                name, cmd,
                exe: p.exe().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default(),
                cwd: p.cwd().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default(),
                anc,
            }
        })
        .collect();
    let nproc = rows.len();
    let row_json = |p: &P| serde_json::json!({
        "cpu": p.cpu, "mem": p.mem, "memp": (p.mem as f64 / total_mem as f64) * 100.0,
        "vms": p.vms, "io": p.io, "io_rt": p.io_rt, "io_wt": p.io_wt, "threads": p.threads,
        "pid": p.pid, "ppid": p.ppid, "user": p.user, "status": p.status, "time": p.time, "start": p.start,
        "name": p.name, "cmd": p.cmd, "exe": p.exe, "cwd": p.cwd, "anc": p.anc,
    });
    // NO cap: root/kernel processes (kworkers, systemd, …) sit near 0% CPU/MEM
    // and a top-N-by-metric cutoff silently excludes them from the FLAT sort
    // views entirely — the table already scrolls, so send every process.
    rows.sort_by(|a, b| b.cpu.partial_cmp(&a.cpu).unwrap_or(Equal));
    let mut by_cpu: Vec<Value> = rows.iter().map(row_json).collect();
    rows.sort_by(|a, b| b.mem.cmp(&a.mem));
    let mut by_mem: Vec<Value> = rows.iter().map(row_json).collect();
    rows.sort_by(|a, b| b.io.cmp(&a.io));
    let mut by_io: Vec<Value> = rows.iter().map(row_json).collect();
    // Every process (compact) for the parent/child TREE view — frontend links
    // children to parents by ppid.
    let mut all_procs: Vec<Value> = rows.iter().map(row_json).collect();
    // Attach each process's cgroup PSI (cpu/io/mem some-avg10). Cached per
    // cgroup so shared scopes are read once.
    let mut psi_cache: HashMap<String, Value> = HashMap::new();
    enrich_psi(&mut by_cpu, &mut psi_cache);
    enrich_psi(&mut by_mem, &mut psi_cache);
    enrich_psi(&mut by_io, &mut psi_cache);
    enrich_psi(&mut all_procs, &mut psi_cache);

    serde_json::json!({
        "host": sysinfo::System::host_name().unwrap_or_default(),
        "os": sysinfo::System::long_os_version().unwrap_or_default(),
        "kernel": sysinfo::System::kernel_version().unwrap_or_default(),
        "uptime": sysinfo::System::uptime(),
        "cpu": sys.global_cpu_usage(),
        "cpu_name": cpu_name,
        "cpu_freq": cpu_freq,
        "ncpu": cores.len(),
        "pcpu": sys.physical_core_count().unwrap_or(0),
        "cores": cores,
        "cores_freq": cores_freq,
        "load": [la.one, la.five, la.fifteen],
        "mem": {
            "total": sys.total_memory(), "used": sys.used_memory(),
            "avail": sys.available_memory(), "free": sys.free_memory(),
            "buffers": buffers, "cached": cached,
            "swap_total": sys.total_swap(), "swap_used": sys.used_swap(),
        },
        "diskio": { "read": dio_r, "write": dio_w },
        "psi": {
            "cpu": read_psi("cpu"), "io": read_psi("io"), "memory": read_psi("memory"),
        },
        "swaps": read_swaps(),
        "zram": read_zram(),
        "power": read_power(),
        "net": net,
        "disks": disk,
        "temps": temps,
        "nproc": nproc,
        "running": running,
        "procs": by_cpu,
        "procs_mem": by_mem,
        "procs_io": by_io,
        "procs_all": all_procs,
    })
}

fn prof_by_name<'a>(profiles: &'a [Value], name: &str) -> Option<&'a Value> {
    profiles.iter().find(|p| p["name"] == Value::String(name.to_string()))
}

fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(|x| x.as_str()).unwrap_or("")
}

// ── Placeholder resolution (mirrors main.ts resolve()) ───────────────
fn resolve(arg: &str, prof: &Value) -> String {
    let flake = s(prof, "flake");
    let sys = prof["flakes"]["system"].as_str().unwrap_or("");
    let desk = prof["flakes"]["desktop"].as_str().unwrap_or("");
    let cloud = prof["flakes"]["cloud"].as_str().unwrap_or("");
    arg.replace("{FLAKE}", flake)
        .replace("{FLAKE_SYSTEM}", sys)
        .replace("{FLAKE_DESKTOP}", desk)
        .replace("{FLAKE_CLOUD}", cloud)
}

fn shq(sh: &str) -> String {
    format!("'{}'", sh.replace('\'', "'\\''"))
}

#[derive(Deserialize)]
struct RunItem {
    #[serde(default)]
    r#type: String,
    #[serde(default)]
    arg: String,
    #[serde(default)]
    profile: Option<String>,
    #[serde(default)]
    #[serde(rename = "ptyId")]
    pty_id: Option<i64>,
}

// ── Central dispatch (mirrors main.ts dispatch()) ─────────────────────
#[tauri::command]
fn run_item(item: RunItem, window: tauri::WebviewWindow, state: tauri::State<AppState>) {
    let prof = item
        .profile
        .as_deref()
        .and_then(|n| prof_by_name(&state.profiles, n))
        .or_else(|| state.profiles.first());
    let Some(prof) = prof else { return };
    let a = resolve(&item.arg, prof);

    // GUI apps → external (xdg-open), detached.
    if item.r#type == "xdg" || item.r#type == "open" {
        let _ = sys_cmd(&state.xdg).arg(&a).spawn();
        return;
    }

    // build / log variants construct a shell line targeting the right flake.
    let line = match item.r#type.as_str() {
        "build" | "build-system" | "build-desktop" => {
            let flake = match item.r#type.as_str() {
                "build" => s(prof, "flake").to_string(),
                "build-system" => nonempty(prof["flakes"]["system"].as_str(), s(prof, "flake")),
                _ => nonempty(prof["flakes"]["desktop"].as_str(), s(prof, "flake")),
            };
            format!("cd {} && PATH=\"/run/wrappers/bin:$PATH\" bash build.sh {}", shq(&flake), a)
        }
        "log" | "log-system" | "log-desktop" => {
            let dir = match item.r#type.as_str() {
                "log" => s(prof, "flake").to_string(),
                "log-system" => nonempty(prof["flakes"]["system"].as_str(), s(prof, "flake")),
                _ => nonempty(prof["flakes"]["desktop"].as_str(), s(prof, "flake")),
            };
            format!("ls -t {}/logs/*.log 2>/dev/null | head -1 | xargs -r tail -f", shq(&dir))
        }
        _ => a, // shell / term → type as-is
    };

    // Type into the tab's PTY (the renderer passes its active tab id).
    let _ = window.show();
    let _ = window.set_focus();
    if let Some(id) = item.pty_id {
        pty_write(&state.ptys, window.label(), id, &format!("{line}\r"));
    }
}

fn nonempty(v: Option<&str>, fallback: &str) -> String {
    match v {
        Some(x) if !x.is_empty() => x.to_string(),
        _ => fallback.to_string(),
    }
}

// ── PTY commands (invoke handlers, mirror ipcMain) ───────────────────
#[tauri::command]
fn pty_start(id: i64, cols: u16, rows: u16, window: tauri::WebviewWindow, state: tauri::State<AppState>) {
    let key = pk(window.label(), id);
    {
        let map = state.ptys.sessions.lock().unwrap();
        if map.contains_key(&key) {
            return;
        }
    }
    let pty_system = native_pty_system();
    let pair = match pty_system.openpty(PtySize {
        rows: rows.max(1),
        cols: cols.max(1),
        pixel_width: 0,
        pixel_height: 0,
    }) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("[ct] openpty failed: {e}");
            return;
        }
    };

    // Login shell (fish -l by default), inheriting env; ensure /run/wrappers/bin
    // precedes so NixOS setuid sudo works (same rule as the old pty-server.js).
    let mut cmd = CommandBuilder::new(&state.shell);
    cmd.arg("-l");
    let base_path = std::env::var("PATH").unwrap_or_default();
    let wrappers = "/run/wrappers/bin";
    if !base_path.split(':').any(|p| p == wrappers) {
        cmd.env("PATH", format!("{wrappers}:{base_path}"));
    }
    cmd.env("TERM", "xterm-256color");
    // The app may be launched with a nix LD_LIBRARY_PATH (webkit/glibc) so its
    // own webview resolves; the PTY inherits our env, so clear it here —
    // otherwise tools run in a tab load nix libs off that path and can break
    // against the system glibc. Interactive shells never need it.
    cmd.env("LD_LIBRARY_PATH", "");
    if let Ok(home) = std::env::var("HOME") {
        cmd.cwd(home);
    }

    let mut child = match pair.slave.spawn_command(cmd) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[ct] spawn shell failed: {e}");
            return;
        }
    };

    let writer = match pair.master.take_writer() {
        Ok(w) => w,
        Err(e) => {
            eprintln!("[ct] take_writer failed: {e}");
            return;
        }
    };
    let mut reader = match pair.master.try_clone_reader() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[ct] clone_reader failed: {e}");
            return;
        }
    };

    state
        .ptys
        .sessions
        .lock()
        .unwrap()
        .insert(key.clone(), PtySession { writer, master: pair.master });

    // Reader thread → emit bytes to the originating window. Events are named
    // per-window ("pty-data:<label>") and emitted GLOBALLY: emit_to()'s target
    // matching proved unreliable (the window's listener never fired → blank
    // terminal), and a unique name also prevents tab-id collisions across the
    // multi-profile windows.
    let app = window.app_handle().clone();
    let win_label = window.label().to_string();
    let ev_data = format!("pty-data:{win_label}");
    let ev_exit = format!("pty-exit:{win_label}");
    let ptys = state.ptys.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let data = String::from_utf8_lossy(&buf[..n]).to_string();
                    let _ = app.emit(&ev_data, (id, data));
                }
            }
        }
        // Shell exited → notify + drop session.
        let _ = child.wait();
        let _ = app.emit(&ev_exit, id);
        ptys.sessions.lock().unwrap().remove(&pk(&win_label, id));
    });
}

fn pty_write(ptys: &PtyManager, window: &str, id: i64, data: &str) {
    if let Some(sess) = ptys.sessions.lock().unwrap().get_mut(&pk(window, id)) {
        let _ = sess.writer.write_all(data.as_bytes());
        let _ = sess.writer.flush();
    }
}

#[tauri::command]
fn pty_input(id: i64, d: String, window: tauri::WebviewWindow, state: tauri::State<AppState>) {
    pty_write(&state.ptys, window.label(), id, &d);
}

#[tauri::command]
fn pty_resize(id: i64, cols: u16, rows: u16, window: tauri::WebviewWindow, state: tauri::State<AppState>) {
    if let Some(sess) = state.ptys.sessions.lock().unwrap().get(&pk(window.label(), id)) {
        let _ = sess.master.resize(PtySize { rows: rows.max(1), cols: cols.max(1), pixel_width: 0, pixel_height: 0 });
    }
}

#[tauri::command]
fn pty_kill(id: i64, window: tauri::WebviewWindow, state: tauri::State<AppState>) {
    state.ptys.sessions.lock().unwrap().remove(&pk(window.label(), id));
}

// Kill a process from the monitor's process table. force=false → SIGTERM
// (graceful), force=true → SIGKILL. Direct libc kill(2) — see send_signal.
#[tauri::command]
fn proc_kill(pid: u32, force: bool) -> Result<(), String> {
    if send_signal(pid, if force { SIGKILL } else { SIGTERM }) { Ok(()) }
    else { Err(std::io::Error::last_os_error().to_string()) }
}

// Memory panic button — runs the existing data-driven `mem-reclaim` engine
// (~/.local/bin/mem-reclaim; cgroup-based, spares the KDE session + this
// terminal/Claude scope). Returns its stdout/stderr summary. dry=true previews.
#[tauri::command]
fn mem_reclaim(dry: bool) -> Result<String, String> {
    let bin = std::env::var("HOME").ok()
        .map(|h| format!("{h}/.local/bin/mem-reclaim"))
        .filter(|p| std::path::Path::new(p).exists())
        .unwrap_or_else(|| "mem-reclaim".to_string());
    let mut cmd = sys_cmd(&bin);
    if dry { cmd.arg("--dry-run"); }
    let out = cmd.output().map_err(|e| format!("{bin}: {e}"))?;
    let mut s = String::from_utf8_lossy(&out.stdout).into_owned();
    s.push_str(&String::from_utf8_lossy(&out.stderr));
    Ok(s)
}

// Zombie reaper. Zombies are already dead; only their parent can reap them,
// so we scan /proc for state 'Z', collect the distinct parents, and send each
// a SIGCHLD to nudge it to wait() (skips init — pid 1 auto-reaps).
#[tauri::command]
fn zombie_reap() -> Result<Value, String> {
    let mut zombies = 0u32;
    let mut parents: std::collections::HashSet<u32> = std::collections::HashSet::new();
    for entry in std::fs::read_dir("/proc").map_err(|e| e.to_string())?.flatten() {
        let pid: u32 = match entry.file_name().to_string_lossy().parse() { Ok(p) => p, Err(_) => continue };
        let stat = match std::fs::read_to_string(format!("/proc/{pid}/stat")) { Ok(s) => s, Err(_) => continue };
        // comm (field 2) is parenthesized and may contain spaces → parse after last ')'.
        let after = match stat.rfind(')') { Some(i) => &stat[i + 1..], None => continue };
        let mut it = after.split_whitespace();
        let state = it.next().unwrap_or("");
        let ppid: u32 = it.next().and_then(|x| x.parse().ok()).unwrap_or(0);
        if state == "Z" { zombies += 1; if ppid > 1 { parents.insert(ppid); } }
    }
    // A SIGCHLD nudge only helps if (a) we're allowed to signal the parent
    // (same uid, or root) and (b) the parent actually calls wait() in
    // response — some parents (root-owned daemons, or ones that already
    // dropped/ignored the pending SIGCHLD) will never reap no matter how
    // many times we signal them. Report real per-parent outcomes instead of
    // unconditionally claiming success — a discarded bool here previously
    // made "parents_nudged" a lie whenever a signal hit EPERM.
    let mut nudged = 0usize;
    let mut denied: Vec<u32> = Vec::new();
    for pp in &parents {
        if send_signal(*pp, SIGCHLD) { nudged += 1; } else { denied.push(*pp); }
    }
    Ok(serde_json::json!({
        "zombies": zombies, "parents_nudged": nudged, "parents_denied": denied,
    }))
}

// ── PSI-targeted reclaim: kill the top resource hog until pressure drops ──
// The kernel's avg10 lags ~10s, so we measure INSTANTANEOUS PSI from the growth
// of the 'some' stall counter over a short window — it reacts the moment the
// hog dies.
fn read_psi_total(kind: &str) -> u64 {
    std::fs::read_to_string(format!("/proc/pressure/{kind}")).ok()
        .and_then(|t| t.lines().find(|l| l.starts_with("some")).map(|s| s.to_string()))
        .and_then(|l| l.split_whitespace().find_map(|kv| kv.strip_prefix("total=").and_then(|v| v.parse::<u64>().ok())))
        .unwrap_or(0)
}
fn instant_psi(kind: &str) -> f64 {
    let t0 = read_psi_total(kind);
    std::thread::sleep(std::time::Duration::from_millis(400));
    let t1 = read_psi_total(kind);
    t1.saturating_sub(t0) as f64 / 400_000.0 * 100.0 // Δµs / 400ms window → % stalled
}
fn cgroup_of(pid: u32) -> String {
    std::fs::read_to_string(format!("/proc/{pid}/cgroup")).ok()
        .and_then(|c| c.lines().find_map(|l| l.strip_prefix("0::")).map(|s| s.trim().to_string()))
        .unwrap_or_default()
}
// Loop: kill the top consumer of `k` (cpu|io|memory) among USER app.slice
// processes (spares the KDE session + this terminal/Claude scope) until
// instantaneous PSI ≤ target%, capped at 8 kills. SIGTERM (graceful) only.
fn psi_reclaim(sysm: &Mutex<sysinfo::System>, k: &str, target: f64) -> Vec<Value> {
    let my_cg = cgroup_of(std::process::id());
    let my_pid = std::process::id();
    let mut killed: Vec<Value> = Vec::new();
    let mut done: std::collections::HashSet<u32> = std::collections::HashSet::new();
    for _ in 0..8 {
        if instant_psi(k) <= target { break; }
        let pick = {
            let mut sys = sysm.lock().unwrap();
            sys.refresh_all();
            let mut best: Option<(u32, f64, String)> = None;
            for (pid, p) in sys.processes() {
                let pidn = pid.as_u32();
                if pidn == my_pid || done.contains(&pidn) { continue; }
                let cg = cgroup_of(pidn);
                if !cg.contains("/app.slice/") || cg == my_cg { continue; } // user apps only, spare our scope
                let metric = match k {
                    "cpu" => p.cpu_usage() as f64,
                    "memory" => p.memory() as f64,
                    _ => { let d = p.disk_usage(); (d.read_bytes + d.written_bytes) as f64 }
                };
                if metric <= 0.0 { continue; }
                if best.as_ref().map_or(true, |b| metric > b.1) {
                    best = Some((pidn, metric, p.name().to_string_lossy().into_owned()));
                }
            }
            best
        };
        match pick {
            Some((pid, metric, name)) => {
                send_signal(pid, SIGTERM);
                done.insert(pid);
                killed.push(serde_json::json!({ "pid": pid, "name": name, "metric": metric }));
                std::thread::sleep(std::time::Duration::from_millis(250));
            }
            None => break,
        }
    }
    killed
}

// One button per resource: reclaim until that resource's PSI ≤ target (default 1%).
#[tauri::command]
fn psi_clean(kind: String, target: Option<f64>, state: tauri::State<AppState>) -> Value {
    let k = match kind.as_str() { "mem" | "memory" => "memory", "io" => "io", _ => "cpu" };
    let tgt = target.unwrap_or(1.0);
    let killed = psi_reclaim(&state.sys, k, tgt);
    serde_json::json!({ "kind": k, "target": tgt, "killed": killed, "final_psi": instant_psi(k) })
}

// Clean All: diagnose which resource has the worst instantaneous pressure, then
// reclaim exactly that one.
#[tauri::command]
fn psi_clean_all(state: tauri::State<AppState>) -> Value {
    let cpu = instant_psi("cpu");
    let io = instant_psi("io");
    let mem = instant_psi("memory");
    let worst = if mem >= cpu && mem >= io { "memory" } else if cpu >= io { "cpu" } else { "io" };
    let killed = psi_reclaim(&state.sys, worst, 1.0);
    serde_json::json!({ "diagnosed": worst, "psi": { "cpu": cpu, "io": io, "memory": mem }, "killed": killed, "final_psi": instant_psi(worst) })
}

// Journal feed: merge system + user journals (last `n` each) as structured
// rows tagged by source. All filtering (scope/priority/unit/search) happens
// client-side over this set, so a filter change needs no re-fetch.
#[tauri::command]
fn journal_feed(n: Option<u32>) -> Result<Value, String> {
    let n = n.unwrap_or(500).to_string();
    let field = |v: &Value, k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
    // MESSAGE is usually a string, but binary/multiline logs arrive as a byte array.
    let message = |v: &Value| -> String {
        match v.get("MESSAGE") {
            Some(Value::String(s)) => s.clone(),
            Some(Value::Array(a)) => String::from_utf8_lossy(
                &a.iter().filter_map(|x| x.as_u64().map(|b| b as u8)).collect::<Vec<u8>>()).into_owned(),
            _ => String::new(),
        }
    };
    let mut rows: Vec<Value> = Vec::new();
    for (src, user) in [("system", false), ("user", true)] {
        let mut cmd = sys_cmd("journalctl");
        cmd.arg("--no-pager").arg("-o").arg("json").arg("-n").arg(&n);
        if user { cmd.arg("--user"); }
        let out = match cmd.output() { Ok(o) => o, Err(_) => continue };
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            let v: Value = match serde_json::from_str(line) { Ok(v) => v, Err(_) => continue };
            let unit = { let s = field(&v, "_SYSTEMD_UNIT"); if s.is_empty() { field(&v, "_SYSTEMD_USER_UNIT") } else { s } };
            let ident = field(&v, "SYSLOG_IDENTIFIER");
            let name = if !unit.is_empty() { unit } else if !ident.is_empty() { ident } else { field(&v, "_COMM") };
            rows.push(serde_json::json!({
                "src": src,
                "t": field(&v, "__REALTIME_TIMESTAMP").parse::<u64>().unwrap_or(0) / 1000, // ms
                "prio": field(&v, "PRIORITY").parse::<u8>().unwrap_or(6),
                "unit": name,
                "pid": field(&v, "_PID"),
                "uid": field(&v, "_UID"),
                "host": field(&v, "_HOSTNAME"),
                "msg": message(&v),
            }));
        }
    }
    rows.sort_by(|a, b| b["t"].as_u64().unwrap_or(0).cmp(&a["t"].as_u64().unwrap_or(0)));
    Ok(Value::Array(rows))
}

// ══ Cloud Control Center — probe VMs + containers over the SSH mesh ══
fn cloud_targets_path() -> String {
    let dir = std::env::var("CT_PROFILES_DIR")
        .unwrap_or_else(|_| format!("{}/data", env_or("CT_APP_DIR", ".")));
    format!("{dir}/cloud-targets.json")
}

#[tauri::command]
fn cloud_targets() -> Value {
    std::fs::read_to_string(cloud_targets_path()).ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .unwrap_or(Value::Null)
}

// SSH into one VM (BatchMode, short timeout) and collect uptime + root-fs use +
// `docker ps` (JSON lines). Read-only + lightweight, safe even on the 1GB E2s.
#[tauri::command]
fn cloud_vm(alias: String) -> Value {
    // One round-trip: uptime, df, then docker ps as JSON lines after a marker.
    let remote = "printf 'UPTIME\\t%s\\n' \"$(uptime -p 2>/dev/null || uptime)\"; \
                  printf 'DISK\\t%s\\n' \"$(df -P / 2>/dev/null | awk 'NR==2{print $5\" \"$4\" \"$2}')\"; \
                  echo '---PS---'; docker ps -a --format '{{json .}}' 2>/dev/null";
    let out = ssh_cmd(&alias).arg(remote).output();
    let out = match out {
        Ok(o) => o,
        Err(e) => return serde_json::json!({ "alias": alias, "reachable": false, "error": e.to_string() }),
    };
    if !out.status.success() && out.stdout.is_empty() {
        let err = String::from_utf8_lossy(&out.stderr).lines().next().unwrap_or("unreachable").to_string();
        return serde_json::json!({ "alias": alias, "reachable": false, "error": err });
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let (mut uptime, mut disk) = (String::new(), String::new());
    let mut containers: Vec<Value> = Vec::new();
    let mut in_ps = false;
    for line in text.lines() {
        if line == "---PS---" { in_ps = true; continue; }
        if !in_ps {
            if let Some(v) = line.strip_prefix("UPTIME\t") { uptime = v.to_string(); }
            else if let Some(v) = line.strip_prefix("DISK\t") { disk = v.to_string(); }
        } else if let Ok(c) = serde_json::from_str::<Value>(line) {
            containers.push(c);
        }
    }
    // df line = "USE% AVAIL TOTAL" (1K blocks for avail/total).
    let mut d = disk.split_whitespace();
    let disk_pct = d.next().unwrap_or("").trim_end_matches('%').parse::<u32>().unwrap_or(0);
    let running = containers.iter().filter(|c| c["State"].as_str() == Some("running")).count();
    serde_json::json!({
        "alias": alias, "reachable": true, "uptime": uptime.trim(),
        "disk_pct": disk_pct, "disk_raw": disk,
        "containers": containers, "n_containers": containers.len(), "n_running": running,
    })
}

// Live per-container resource stats via `docker stats` over the SSH mux.
// Refresh-triggered only (the frontend calls this on the refresh button), so
// no streaming; --no-stream takes one sample. Reuses the ControlMaster socket.
#[tauri::command]
fn cloud_stats(alias: String) -> Value {
    let out = ssh_cmd(&alias).arg("docker stats --no-stream --format '{{json .}}' 2>/dev/null").output();
    let mut stats: Vec<Value> = Vec::new();
    if let Ok(o) = out {
        for line in String::from_utf8_lossy(&o.stdout).lines() {
            if let Ok(v) = serde_json::from_str::<Value>(line) { stats.push(v); }
        }
    }
    serde_json::json!({ "alias": alias, "stats": stats })
}

// Tail a container's logs (or the VM journal when container is empty) over SSH.
#[tauri::command]
fn cloud_logs(alias: String, container: Option<String>, tail: Option<u32>) -> Result<String, String> {
    let n = tail.unwrap_or(200).to_string();
    let remote = match container.as_deref() {
        Some(c) if !c.is_empty() => format!("docker logs --timestamps --tail {n} {} 2>&1", shq(c)),
        _ => format!("journalctl --no-pager -n {n} 2>&1 || sudo journalctl --no-pager -n {n} 2>&1"),
    };
    let out = ssh_cmd(&alias).arg(&remote).output().map_err(|e| e.to_string())?;
    let mut s = String::from_utf8_lossy(&out.stdout).into_owned();
    if s.is_empty() { s = String::from_utf8_lossy(&out.stderr).into_owned(); }
    Ok(s)
}

// Quick public-edge ping (curl). Returns HTTP code + latency; body is read so
// the Caddy wormhole-200 fallback doesn't read as a false 'up'.
#[tauri::command]
fn cloud_ping(url: String) -> Value {
    let out = sys_cmd("curl")
        .args(["-sS", "-o", "/dev/null", "-m", "8", "-w", "%{http_code} %{time_total}", &url])
        .output();
    match out {
        Ok(o) => {
            let s = String::from_utf8_lossy(&o.stdout);
            let mut it = s.split_whitespace();
            let code = it.next().unwrap_or("0").parse::<u32>().unwrap_or(0);
            let ms = (it.next().unwrap_or("0").parse::<f64>().unwrap_or(0.0) * 1000.0) as u32;
            serde_json::json!({ "url": url, "code": code, "ms": ms, "up": code > 0 && code < 500 })
        }
        Err(e) => serde_json::json!({ "url": url, "code": 0, "up": false, "error": e.to_string() }),
    }
}

// ══ Data Sync Center — local data topology + peers + releases ═══════
fn sh_out(prog: &str, args: &[&str]) -> String {
    sys_cmd(prog).args(args).output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default()
}
fn data_cfg() -> Value {
    let dir = std::env::var("CT_PROFILES_DIR").unwrap_or_else(|_| format!("{}/data", env_or("CT_APP_DIR", ".")));
    std::fs::read_to_string(format!("{dir}/data-sync.json")).ok()
        .and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null)
}

// Fast local aggregate: mounts, docker volumes, fuse, usb, rclone remotes, git
// repo statuses + the data-driven config (peers / rules). No network.
#[tauri::command]
fn data_sync() -> Value {
    let cfg = data_cfg();
    let home = env_or("HOME", "/home");
    // Mounts (bytes). Keep real filesystems; split out fuse.* for its own panel.
    let real = ["btrfs", "ext4", "ext3", "vfat", "xfs", "zfs", "ntfs", "ntfs3", "exfat"];
    let mnt_json: Value = serde_json::from_str(&sh_out("findmnt", &["-J", "-l", "-b", "-o", "TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL,USE%"])).unwrap_or(Value::Null);
    let (mut mounts, mut fuse) = (Vec::new(), Vec::new());
    // btrfs subvolumes share one pool device (source "/dev/mapper/pool[/@sub]"),
    // so every subvol reports the SAME size/used/% — dedupe by the base device
    // (strip the "[…]" subvol suffix) so each PHYSICAL filesystem shows once.
    let mut seen_dev = std::collections::HashSet::new();
    if let Some(fs) = mnt_json["filesystems"].as_array() {
        for m in fs {
            let ft = m["fstype"].as_str().unwrap_or("");
            let row = serde_json::json!({
                "target": m["target"], "source": m["source"], "fstype": ft,
                "size": m["size"], "used": m["used"], "avail": m["avail"], "usep": m["use%"],
            });
            if ft.starts_with("fuse") { fuse.push(row); }
            else if real.contains(&ft) {
                let src = m["source"].as_str().unwrap_or("");
                let base = src.split('[').next().unwrap_or(src).to_string();
                if seen_dev.insert(base) { mounts.push(row); }
            }
        }
    }
    // Docker volumes
    let volumes: Vec<Value> = sh_out("docker", &["volume", "ls", "--format", "{{json .}}"])
        .lines().filter_map(|l| serde_json::from_str::<Value>(l).ok()).collect();
    // USB / removable
    let lsblk: Value = serde_json::from_str(&sh_out("lsblk", &["-J", "-b", "-o", "NAME,RM,SIZE,TYPE,MOUNTPOINT,FSTYPE,LABEL"])).unwrap_or(Value::Null);
    let mut usb = Vec::new();
    if let Some(bd) = lsblk["blockdevices"].as_array() {
        for d in bd { if d["rm"].as_bool() == Some(true) || d["rm"].as_i64() == Some(1) { usb.push(d.clone()); } }
    }
    // rclone remotes (name → {type})
    let rclone: Value = serde_json::from_str(&sh_out("rclone", &["config", "dump"])).unwrap_or(Value::Null);
    let remotes: Vec<Value> = rclone.as_object().map(|o| o.iter().map(|(k, v)|
        serde_json::json!({ "name": k, "type": v["type"].as_str().unwrap_or("") })).collect()).unwrap_or_default();
    // Git repos
    let groot = cfg["git_root"].as_str().unwrap_or("git");
    let mut repos = Vec::new();
    if let Some(list) = cfg["git_repos"].as_array() {
        for r in list.iter().filter_map(|x| x.as_str()) {
            let dir = format!("{home}/{groot}/{r}");
            if !std::path::Path::new(&dir).exists() { continue; }
            let g = |a: &[&str]| { let mut v = vec!["-C", &dir]; v.extend_from_slice(a); sh_out("git", &v).trim().to_string() };
            let ab = g(&["rev-list", "--left-right", "--count", "@{u}...HEAD"]);
            let mut abi = ab.split_whitespace();
            let dirty = sh_out("git", &["-C", &dir, "status", "--porcelain"]).lines().count();
            repos.push(serde_json::json!({
                "name": r, "branch": g(&["rev-parse", "--abbrev-ref", "HEAD"]),
                "behind": abi.next().unwrap_or("0").parse::<u32>().unwrap_or(0),
                "ahead": abi.next().unwrap_or("0").parse::<u32>().unwrap_or(0),
                "dirty": dirty, "last": g(&["log", "-1", "--format=%h · %cr · %s"]),
            }));
        }
    }
    serde_json::json!({
        "mounts": mounts, "fuse": fuse, "volumes": volumes, "usb": usb,
        "remotes": remotes, "repos": repos,
        "peers": cfg["peers"], "rclone_rules": cfg["rclone_rules"],
        "s3_types": cfg["s3_remote_types"], "gh_repos": cfg["gh_repos"],
    })
}

// GHCR container packages + latest GitHub releases (network; called separately
// so the dashboard renders instantly then fills these in).
#[tauri::command]
fn data_gh() -> Value {
    let ghcr: Value = serde_json::from_str(&sh_out("gh", &["api", "user/packages?package_type=container&per_page=100",
        "--jq", "[.[]|{name:.name, versions:.version_count, visibility:.visibility, updated:.updated_at}]"])).unwrap_or(Value::Array(vec![]));
    let mut releases = Vec::new();
    let cfg = data_cfg();
    if let Some(repos) = cfg["gh_repos"].as_array() {
        for r in repos.iter().filter_map(|x| x.as_str()) {
            let out = sh_out("gh", &["release", "list", "--repo", r, "--limit", "5", "--json", "tagName,name,publishedAt,isLatest"]);
            if let Ok(v) = serde_json::from_str::<Value>(&out) {
                if let Some(a) = v.as_array() { if !a.is_empty() { releases.push(serde_json::json!({ "repo": r, "releases": v })); } }
            }
        }
    }
    serde_json::json!({ "ghcr": ghcr, "releases": releases })
}

// Peer reachability for the sync-peers panel. local → always up; ssh → probe.
#[tauri::command]
fn peer_ping(host: String, local: bool) -> Value {
    if local { return serde_json::json!({ "host": host, "up": true, "info": "this machine" }); }
    let out = ssh_cmd(&host).arg("echo up; uptime -p 2>/dev/null").output();
    match out {
        Ok(o) if o.status.success() => {
            let s = String::from_utf8_lossy(&o.stdout);
            let info = s.lines().nth(1).unwrap_or("").trim().to_string();
            serde_json::json!({ "host": host, "up": true, "info": info })
        }
        _ => serde_json::json!({ "host": host, "up": false, "info": "unreachable" }),
    }
}

// ── Session persistence (~/.cloud-terminal/session.json) ────────────
// Per-profile tab lists (type/title/cmd — NOT PTY state) so the app reopens
// with the same tabs per profile. Written on every tab open/close/switch
// (debounced client-side), read once at boot.
fn session_path() -> String {
    format!("{}/.cloud-terminal/session.json", env_or("HOME", "/tmp"))
}
#[tauri::command]
fn session_save(data: Value) -> Result<(), String> {
    let p = session_path();
    if let Some(dir) = std::path::Path::new(&p).parent() { std::fs::create_dir_all(dir).map_err(|e| e.to_string())?; }
    std::fs::write(&p, serde_json::to_string(&data).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}
#[tauri::command]
fn session_load() -> Value {
    std::fs::read_to_string(session_path()).ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null)
}

// ══ AGI dashboard — Claude Code usage analytics ══════════════════════
// Reads the SAME sources the statusline reads: per-session transcripts
// (~/.claude/projects/**/*.jsonl, one assistant-message-with-usage row per
// API call) and ~/.claude/claude-pricing.json (per-model USD/MTok rates,
// longest-model-id-prefix-wins — identical lookup to statusline-command.sh).
// Aggregates into totals, per-model, per-day (30d), per-5h-cycle (~16d), and
// per-session breakdowns, plus the live/current session. Refresh-triggered
// only (parsing ~200+ JSONL files is not something to do on a timer).

// Howard Hinnant's civil_from_days / days_from_civil — no chrono dependency
// needed for plain Y-M-D + epoch-second math.
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as i64;
    let mp = (m as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}
// "2026-07-03T13:48:41.105Z" → (epoch_secs, "2026-07-03")
fn parse_iso(ts: &str) -> Option<(i64, String)> {
    let b = ts.as_bytes();
    if b.len() < 19 { return None; }
    let y: i64 = ts.get(0..4)?.parse().ok()?;
    let mo: u32 = ts.get(5..7)?.parse().ok()?;
    let d: u32 = ts.get(8..10)?.parse().ok()?;
    let hh: i64 = ts.get(11..13)?.parse().ok()?;
    let mm: i64 = ts.get(14..16)?.parse().ok()?;
    let ss: i64 = ts.get(17..19)?.parse().ok()?;
    let epoch = days_from_civil(y, mo, d) * 86400 + hh * 3600 + mm * 60 + ss;
    Some((epoch, ts[0..10].to_string()))
}
fn epoch_to_iso_minute(e: i64) -> String {
    let days = e.div_euclid(86400);
    let secs = e.rem_euclid(86400);
    let (y, mo, d) = civil_from_days(days);
    format!("{y:04}-{mo:02}-{d:02} {:02}:{:02}", secs / 3600, (secs % 3600) / 60)
}

#[derive(Default, Clone)]
struct UsageTotals { input: u64, output: u64, cache_read: u64, cache_write: u64, cost: f64, messages: u64 }
impl UsageTotals {
    fn add(&mut self, i: u64, o: u64, cr: u64, cw: u64, cost: f64) {
        self.input += i; self.output += o; self.cache_read += cr; self.cache_write += cw;
        self.cost += cost; self.messages += 1;
    }
    fn json(&self) -> Value {
        serde_json::json!({ "input": self.input, "output": self.output, "cache_read": self.cache_read,
            "cache_write": self.cache_write, "cost": (self.cost * 10000.0).round() / 10000.0, "messages": self.messages })
    }
}

// Longest-model-id-prefix match against claude-pricing.json's `models` map,
// else `default` — IDENTICAL lookup to statusline-command.sh so the $ shown
// here always agrees with the statusline.
fn pricing_for(pricing: &Value, model: &str) -> (f64, f64, f64, f64) {
    let get = |v: &Value| (
        v["input"].as_f64().unwrap_or(15.0), v["output"].as_f64().unwrap_or(75.0),
        v["cache_read"].as_f64().unwrap_or(1.50), v["cache_write"].as_f64().unwrap_or(18.75),
    );
    if let Some(models) = pricing["models"].as_object() {
        let best = models.iter().filter(|(k, _)| model.starts_with(k.as_str()))
            .max_by_key(|(k, _)| k.len());
        if let Some((_, v)) = best { return get(v); }
    }
    if pricing["default"].is_object() { get(&pricing["default"]) } else { (15.0, 75.0, 1.50, 18.75) }
}

fn walk_jsonl(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() { walk_jsonl(&p, out); }
        else if p.extension().map_or(false, |x| x == "jsonl") { out.push(p); }
    }
}

#[tauri::command]
fn agi_usage() -> Value {
    let home = env_or("HOME", "/tmp");
    let proj_dir = std::path::PathBuf::from(format!("{home}/.claude/projects"));
    let pricing: Value = std::fs::read_to_string(format!("{home}/.claude/claude-pricing.json")).ok()
        .and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null);

    let mut files = Vec::new();
    walk_jsonl(&proj_dir, &mut files);
    files.sort_by_key(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok());

    let mut total = UsageTotals::default();
    let mut by_model: std::collections::HashMap<String, UsageTotals> = std::collections::HashMap::new();
    let mut by_day: std::collections::HashMap<String, UsageTotals> = std::collections::HashMap::new();
    let mut by_5h: std::collections::HashMap<i64, UsageTotals> = std::collections::HashMap::new();
    struct Sess { project: String, first: i64, last: i64, model: String, t: UsageTotals }
    let mut sessions: std::collections::HashMap<String, Sess> = std::collections::HashMap::new();

    for path in &files {
        let sid = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let project = path.parent().and_then(|p| p.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let Ok(text) = std::fs::read_to_string(path) else { continue };
        for line in text.lines() {
            if !line.contains("\"usage\"") { continue; }
            let Ok(d) = serde_json::from_str::<Value>(line) else { continue };
            let msg = &d["message"];
            let Some(u) = msg.get("usage") else { continue };
            if msg.get("role").and_then(|r| r.as_str()) != Some("assistant") { continue; }
            let ts = d["timestamp"].as_str().unwrap_or("");
            let Some((epoch, day)) = parse_iso(ts) else { continue };
            let model = msg["model"].as_str().unwrap_or("unknown").to_string();
            let i = u["input_tokens"].as_u64().unwrap_or(0);
            let o = u["output_tokens"].as_u64().unwrap_or(0);
            let cr = u["cache_read_input_tokens"].as_u64().unwrap_or(0);
            let cw = u["cache_creation_input_tokens"].as_u64().unwrap_or(0);
            let (pi, po, pcr, pcw) = pricing_for(&pricing, &model);
            let cost = i as f64 / 1e6 * pi + o as f64 / 1e6 * po + cr as f64 / 1e6 * pcr + cw as f64 / 1e6 * pcw;

            total.add(i, o, cr, cw, cost);
            by_model.entry(model.clone()).or_default().add(i, o, cr, cw, cost);
            by_day.entry(day).or_default().add(i, o, cr, cw, cost);
            by_5h.entry(epoch.div_euclid(5 * 3600)).or_default().add(i, o, cr, cw, cost);
            let s = sessions.entry(sid.clone()).or_insert_with(|| Sess { project: project.clone(), first: epoch, last: epoch, model: model.clone(), t: UsageTotals::default() });
            s.last = epoch.max(s.last); s.first = epoch.min(s.first); s.model = model.clone();
            s.t.add(i, o, cr, cw, cost);
        }
    }

    // by_day: EVERY day with recorded usage (no cap — matches the "show ALL
    // history" sessions list; a fixed day-count cap silently truncated to
    // whatever the last 30 *populated* days were, which could be months
    // shorter than the real history on sparse-usage stretches).
    let mut days: Vec<(String, UsageTotals)> = by_day.into_iter().collect();
    days.sort_by(|a, b| a.0.cmp(&b.0));

    // by_5h: last 80 buckets (~16.6 days), sorted ascending, labeled by bucket start.
    let mut buckets: Vec<(i64, UsageTotals)> = by_5h.into_iter().collect();
    buckets.sort_by_key(|b| b.0);
    if buckets.len() > 80 { let n = buckets.len(); buckets.drain(0..n - 80); }

    // sessions: EVERY session ever recorded on disk (no cap — real, full
    // history), sorted by last-active desc.
    let mut sess_vec: Vec<(String, Sess)> = sessions.into_iter().collect();
    sess_vec.sort_by(|a, b| b.1.last.cmp(&a.1.last));
    let current = sess_vec.first();
    let current_json = current.map(|(id, s)| serde_json::json!({
        "id": id, "project": s.project, "model": s.model,
        "started": epoch_to_iso_minute(s.first), "last_active": epoch_to_iso_minute(s.last),
        "duration_min": (s.last - s.first) / 60, "usage": s.t.json(),
    })).unwrap_or(Value::Null);

    serde_json::json!({
        "total": total.json(),
        "by_model": by_model.iter().map(|(m, t)| serde_json::json!({ "model": m, "usage": t.json() })).collect::<Vec<_>>(),
        "by_day": days.iter().map(|(d, t)| serde_json::json!({ "date": d, "usage": t.json() })).collect::<Vec<_>>(),
        "by_5h": buckets.iter().map(|(b, t)| serde_json::json!({ "start": epoch_to_iso_minute(b * 5 * 3600), "usage": t.json() })).collect::<Vec<_>>(),
        "sessions": sess_vec.iter().map(|(id, s)| serde_json::json!({
            "id": id, "project": s.project, "model": s.model,
            "started": epoch_to_iso_minute(s.first), "last_active": epoch_to_iso_minute(s.last),
            "duration_min": (s.last - s.first) / 60, "usage": s.t.json(),
        })).collect::<Vec<_>>(),
        "current": current_json,
        "file_count": files.len(),
    })
}

// Lightweight LIVE poll for the current session banner — reads ONLY the
// single most-recently-modified transcript (one file, not the full 200+
// history agi_usage scans), so this is cheap enough to call every few
// seconds. Same pricing lookup, same shape as agi_usage's "current".
#[tauri::command]
fn agi_live() -> Value {
    let home = env_or("HOME", "/tmp");
    let proj_dir = std::path::PathBuf::from(format!("{home}/.claude/projects"));
    let pricing: Value = std::fs::read_to_string(format!("{home}/.claude/claude-pricing.json")).ok()
        .and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null);

    let mut files = Vec::new();
    walk_jsonl(&proj_dir, &mut files);
    let newest = files.into_iter().max_by_key(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok());
    let Some(path) = newest else { return Value::Null };

    let sid = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let project = path.parent().and_then(|p| p.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let Ok(text) = std::fs::read_to_string(&path) else { return Value::Null };

    let mut t = UsageTotals::default();
    let (mut first, mut last, mut model) = (i64::MAX, 0i64, String::from("unknown"));
    for line in text.lines() {
        if !line.contains("\"usage\"") { continue; }
        let Ok(d) = serde_json::from_str::<Value>(line) else { continue };
        let msg = &d["message"];
        let Some(u) = msg.get("usage") else { continue };
        if msg.get("role").and_then(|r| r.as_str()) != Some("assistant") { continue; }
        let ts = d["timestamp"].as_str().unwrap_or("");
        let Some((epoch, _)) = parse_iso(ts) else { continue };
        model = msg["model"].as_str().unwrap_or("unknown").to_string();
        let i = u["input_tokens"].as_u64().unwrap_or(0);
        let o = u["output_tokens"].as_u64().unwrap_or(0);
        let cr = u["cache_read_input_tokens"].as_u64().unwrap_or(0);
        let cw = u["cache_creation_input_tokens"].as_u64().unwrap_or(0);
        let (pi, po, pcr, pcw) = pricing_for(&pricing, &model);
        let cost = i as f64 / 1e6 * pi + o as f64 / 1e6 * po + cr as f64 / 1e6 * pcr + cw as f64 / 1e6 * pcw;
        t.add(i, o, cr, cw, cost);
        first = first.min(epoch); last = last.max(epoch);
    }
    if t.messages == 0 { return Value::Null; }
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(last);

    serde_json::json!({
        "id": sid, "project": project, "model": model,
        "started": epoch_to_iso_minute(first), "last_active": epoch_to_iso_minute(last),
        "duration_min": (last - first) / 60, "seconds_since_last": (now - last).max(0), "usage": t.json(),
    })
}

// ── init payload for the renderer (mirrors the Electron 'init' send) ──
#[tauri::command]
fn get_init(window: tauri::WebviewWindow, state: tauri::State<AppState>) -> Value {
    // Window label == profile name (set at creation). Return that profile,
    // merged with the full profiles list so the renderer can draw pills.
    let name = window.label();
    let prof = prof_by_name(&state.profiles, name)
        .or_else(|| state.profiles.first())
        .cloned()
        .unwrap_or(Value::Null);
    let host = std::fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|s| s.trim().to_string())
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_default();
    let mut out = prof;
    if let Value::Object(ref mut m) = out {
        m.insert("profiles".into(), Value::Array(state.profiles.clone()));
        m.insert("host".into(), Value::String(host));
    }
    out
}

// ── Tray menu (data-driven from profile sections) ────────────────────
fn build_and_show(app: &AppHandle) {
    let state = app.state::<AppState>();
    let multi = std::env::var("CT_MULTI").is_ok();
    let primary = env_or("CT_PROFILE", "home");
    let assets_dir = env_or(
        "CT_ASSETS_DIR",
        &format!("{}/assets", env_or("CT_APP_DIR", ".")),
    );

    let own: Vec<Value> = if multi {
        state.profiles.clone()
    } else {
        vec![prof_by_name(&state.profiles, &primary)
            .or_else(|| state.profiles.first())
            .cloned()
            .unwrap_or(Value::Null)]
    };

    for prof in own {
        let name = s(&prof, "name").to_string();
        if name.is_empty() {
            continue;
        }

        // Hidden panel window, label == profile name.
        let bg = prof["theme"]["bg"].as_str().unwrap_or("#0e0f1a").to_string();
        let win = WebviewWindowBuilder::new(app, &name, WebviewUrl::App("index.html".into()))
            .title(format!("Cloud Terminal — {}", s(&prof, "display_name")))
            .inner_size(1040.0, 660.0)
            .visible(false)
            .build();
        let win = match win {
            Ok(w) => w,
            Err(e) => {
                eprintln!("[ct] window build failed for {name}: {e}");
                continue;
            }
        };
        // Hide (not quit) on close — tray-managed.
        {
            let w2 = win.clone();
            win.on_window_event(move |ev| {
                if let tauri::WindowEvent::CloseRequested { api, .. } = ev {
                    api.prevent_close();
                    let _ = w2.hide();
                }
            });
        }
        let _ = bg; // reserved: could set window bg once Tauri exposes it

        // ── Tray with data-driven menu ──
        let mut menu = MenuBuilder::new(app)
            .text("open", format!("{}  Open Panel", s(&prof, "logo")))
            .separator();
        // Sections → submenus of command items. Item id encodes profile+index
        // so on_menu_event can look the item back up.
        if let Some(sections) = prof["sections"].as_array() {
            for (si, section) in sections.iter().enumerate() {
                let mut sub = SubmenuBuilder::new(app, s(section, "title"));
                if let Some(items) = section["items"].as_array() {
                    for (ii, it) in items.iter().enumerate() {
                        let id = format!("cmd:{name}:{si}:{ii}");
                        sub = sub.item(&MenuItemBuilder::with_id(id, s(it, "label")).build(app).unwrap());
                    }
                }
                menu = menu.item(&sub.build().unwrap());
            }
        }
        let menu = menu.separator().text("quit", "Quit").build().unwrap();

        let icon_path = format!("{assets_dir}/{name}.png");
        // Unique id per profile + set BOTH title and tooltip: the
        // libayatana-appindicator backend ignores tooltips, but KDE's SNI shows
        // the item title on hover — so each tray gets its own profile name.
        let tip = nonempty(prof["tray_tooltip"].as_str(), s(&prof, "display_name"));
        let mut tray = TrayIconBuilder::with_id(name.clone())
            .title(tip.clone())
            .tooltip(tip)
            .menu(&menu);
        if let Ok(img) = tauri::image::Image::from_path(&icon_path) {
            tray = tray.icon(img);
        }
        let win_label = name.clone();
        let tray = tray
            .on_tray_icon_event(move |tray, event| {
                if let TrayIconEvent::Click { .. } = event {
                    if let Some(w) = tray.app_handle().get_webview_window(&win_label) {
                        if w.is_visible().unwrap_or(false) {
                            let _ = w.hide();
                        } else {
                            let _ = w.show();
                            let _ = w.set_focus();
                        }
                    }
                }
            })
            .on_menu_event(move |app, ev| on_menu(app, ev.id().as_ref()))
            .build(app);
        if let Err(e) = tray {
            eprintln!("[ct] tray build failed for {name}: {e}");
        }
    }

    // --show on the primary window.
    if std::env::args().any(|a| a == "--show") {
        if let Some(w) = app.get_webview_window(&primary).or_else(|| {
            state.profiles.first().and_then(|p| app.get_webview_window(s(p, "name")))
        }) {
            let _ = w.show();
            let _ = w.set_focus();
        }
    }
}

// Tray menu click → open panel / quit / run a command in the profile window.
fn on_menu(app: &AppHandle, id: &str) {
    if id == "quit" {
        app.exit(0);
        return;
    }
    if id == "open" {
        // Show the first window (single-mode) — label unknown here, so show all.
        for w in app.webview_windows().values() {
            let _ = w.show();
            let _ = w.set_focus();
            break;
        }
        return;
    }
    // cmd:<profile>:<si>:<ii>
    let parts: Vec<&str> = id.splitn(4, ':').collect();
    if parts.len() == 4 && parts[0] == "cmd" {
        let state = app.state::<AppState>();
        let (pname, si, ii) = (parts[1], parts[2], parts[3]);
        if let (Some(prof), Ok(si), Ok(ii)) =
            (prof_by_name(&state.profiles, pname), si.parse::<usize>(), ii.parse::<usize>())
        {
            let item = &prof["sections"][si]["items"][ii];
            if let Some(w) = app.get_webview_window(pname) {
                let _ = w.show();
                let _ = w.set_focus();
                // Hand the item to the renderer so it runs in the active tab
                // (same path as a sidebar click). xdg items open externally.
                if s(item, "type") == "xdg" || s(item, "type") == "open" {
                    run_item(
                        serde_json::from_value(item.clone()).unwrap_or(RunItem {
                            r#type: "xdg".into(),
                            arg: s(item, "arg").into(),
                            profile: Some(pname.into()),
                            pty_id: None,
                        }),
                        w,
                        state,
                    );
                } else {
                    let mut payload = item.clone();
                    if let Value::Object(ref mut m) = payload {
                        m.insert("profile".into(), Value::String(pname.into()));
                    }
                    let _ = w.emit(&format!("tray-run:{pname}"), payload);
                }
            }
        }
    }
}

// ── Load profiles from CT_PROFILES_DIR ───────────────────────────────
fn load_profiles(dir: &str) -> Vec<Value> {
    let mut files: Vec<_> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with("profile-") && n.ends_with(".json"))
                .unwrap_or(false)
        })
        .collect();
    files.sort();
    let mut profiles: Vec<Value> = files
        .iter()
        .filter_map(|p| std::fs::read_to_string(p).ok())
        .filter_map(|s| serde_json::from_str::<Value>(&s).ok())
        .collect();
    // Order pills + trays by the profile's `order` field (data-driven); entries
    // without one sort last, then by filename. Lets Home sit leftmost.
    profiles.sort_by(|a, b| {
        let oa = a.get("order").and_then(|v| v.as_i64()).unwrap_or(i64::MAX);
        let ob = b.get("order").and_then(|v| v.as_i64()).unwrap_or(i64::MAX);
        oa.cmp(&ob)
    });
    profiles
}

fn main() {
    let app_dir = env_or("CT_APP_DIR", ".");
    let profiles_dir = env_or("CT_PROFILES_DIR", &format!("{app_dir}/data"));
    let profiles = load_profiles(&profiles_dir);
    if profiles.is_empty() {
        eprintln!("[ct] no profiles found in {profiles_dir}");
        std::process::exit(1);
    }

    let state = AppState {
        profiles,
        ptys: Arc::new(PtyManager::default()),
        xdg: env_or("CT_XDG", "xdg-open"),
        shell: env_or("CT_SHELL", "fish"),
        sys: Mutex::new(sysinfo::System::new_all()),
        nets: Mutex::new(sysinfo::Networks::new_with_refreshed_list()),
    };

    tauri::Builder::default()
        // Single-instance guard MUST be the first plugin registered. A second
        // `cloud-terminal` launch runs this callback in the ALREADY-running
        // process (then the new process exits) — so instead of a duplicate
        // 3-tray set, we just reveal the existing windows. If the relaunch
        // named a profile (argv), prefer showing that one's window.
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            let want = argv.iter().rev().find(|a| !a.starts_with('-') && *a != "cloud-terminal").cloned();
            let target = want.and_then(|n| app.get_webview_window(&n));
            match target {
                Some(w) => { let _ = w.show(); let _ = w.set_focus(); }
                None => for w in app.webview_windows().values() { let _ = w.show(); let _ = w.set_focus(); }
            }
        }))
        .manage(state)
        .invoke_handler(tauri::generate_handler![
            pty_start, pty_input, pty_resize, pty_kill, proc_kill, mem_reclaim, zombie_reap,
            psi_clean, psi_clean_all, journal_feed,
            cloud_targets, cloud_vm, cloud_stats, cloud_logs, cloud_ping, data_sync, data_gh, peer_ping,
            session_save, session_load, agi_usage, agi_live,
            run_item, get_init, sys_stats
        ])
        .setup(|app| {
            build_and_show(&app.handle().clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
