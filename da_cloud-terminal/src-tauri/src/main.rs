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
    struct P { cpu: f32, mem: u64, io: u64, pid: u32, ppid: u32, user: String, status: String, time: u64, name: String, cmd: String, anc: Vec<String> }
    let mut rows: Vec<P> = sys
        .processes()
        .iter()
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
            P { cpu: p.cpu_usage(), mem: p.memory(), io: du.read_bytes + du.written_bytes,
                pid: pid.as_u32(), ppid, user, status: st, time: p.run_time(), name, cmd, anc }
        })
        .collect();
    let nproc = rows.len();
    let row_json = |p: &P| serde_json::json!({
        "cpu": p.cpu, "mem": p.mem, "memp": (p.mem as f64 / total_mem as f64) * 100.0, "io": p.io,
        "pid": p.pid, "ppid": p.ppid, "user": p.user, "status": p.status, "time": p.time,
        "name": p.name, "cmd": p.cmd, "anc": p.anc,
    });
    rows.sort_by(|a, b| b.cpu.partial_cmp(&a.cpu).unwrap_or(Equal));
    let by_cpu: Vec<Value> = rows.iter().take(30).map(row_json).collect();
    rows.sort_by(|a, b| b.mem.cmp(&a.mem));
    let by_mem: Vec<Value> = rows.iter().take(30).map(row_json).collect();
    rows.sort_by(|a, b| b.io.cmp(&a.io));
    let by_io: Vec<Value> = rows.iter().take(30).map(row_json).collect();
    // Every process (compact) for the parent/child TREE view — frontend links
    // children to parents by ppid.
    let all_procs: Vec<Value> = rows.iter().map(row_json).collect();

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
        let _ = std::process::Command::new(&state.xdg).arg(&a).spawn();
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
// (graceful), force=true → SIGKILL. Shells out to `kill` (no libc dep).
#[tauri::command]
fn proc_kill(pid: u32, force: bool) -> Result<(), String> {
    let sig = if force { "-KILL" } else { "-TERM" };
    std::process::Command::new("kill")
        .arg(sig)
        .arg(pid.to_string())
        .status()
        .map_err(|e| e.to_string())
        .and_then(|s| if s.success() { Ok(()) } else { Err(format!("kill exited {s}")) })
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
    let primary = env_or("CT_PROFILE", "nix-flakes");
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
            pty_start, pty_input, pty_resize, pty_kill, proc_kill, run_item, get_init, sys_stats
        ])
        .setup(|app| {
            build_and_show(&app.handle().clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
