// watchdog.rs — ONE process reads the machine, everything else reads a file.
//
// This exists because of what the KDE panel cost. Fourteen
// org.kde.plasma.systemmonitor applets each build a sensor-face controller, a
// KQuickCharts scene graph and their own ksystemstats subscriptions, and
// plasmashell settled at ~24% CPU and 410MB of which 135MB was QML JS heap —
// on a panel showing eight numbers. Reading /proc was never the expensive
// part: ksystemstats, which actually does it, costs 2.5%. Fourteen QML
// sub-applications maintaining chart geometry is.
//
// Same shape as the fix that worked twice already today: the Claude status
// line went from a 4.6s jq slurp per paint to reading one published JSON, and
// my-ai's usage daemon went from 134MB to 13MB once one process did the work.
// So the tray daemon — which already runs permanently under Restart=always —
// samples once and writes a snapshot, and the panel widgets become Text
// elements over a Timer. Cost stops scaling with how many numbers you show.
use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;

const INTERVAL_MS: u64 = 2_000;

pub fn snapshot_path() -> Option<PathBuf> {
    std::env::var_os("XDG_RUNTIME_DIR").map(|d| PathBuf::from(d).join("my-konsole-watchdog.json"))
}

// /proc/stat's cpu line is cumulative since boot, so a percentage needs two
// samples. Kept between ticks rather than sleeping inside the reader.
#[derive(Default, Clone, Copy)]
struct CpuTotals {
    idle: u64,
    total: u64,
}

fn parse_cpu_line(line: &str) -> CpuTotals {
    let v: Vec<u64> = line
        .split_whitespace()
        .skip(1)
        .filter_map(|x| x.parse().ok())
        .collect();
    // user nice system idle iowait irq softirq steal …
    let idle = v.get(3).copied().unwrap_or(0) + v.get(4).copied().unwrap_or(0);
    CpuTotals { idle, total: v.iter().sum() }
}

/// Aggregate plus one entry per core. The panel wants per-core bars, and
/// /proc/stat already carries them — sampling the aggregate separately would
/// read the same file twice for numbers that must agree.
fn read_cpu_all() -> (CpuTotals, Vec<CpuTotals>) {
    let Ok(s) = fs::read_to_string("/proc/stat") else { return (CpuTotals::default(), Vec::new()) };
    let mut agg = CpuTotals::default();
    let mut cores = Vec::new();
    for l in s.lines() {
        if !l.starts_with("cpu") {
            break; // the cpu* lines are contiguous and first
        }
        if l.starts_with("cpu ") {
            agg = parse_cpu_line(l);
        } else {
            cores.push(parse_cpu_line(l));
        }
    }
    (agg, cores)
}

fn cpu_percent(prev: CpuTotals, now: CpuTotals) -> f64 {
    let dt = now.total.saturating_sub(prev.total);
    if dt == 0 {
        return 0.0;
    }
    let di = now.idle.saturating_sub(prev.idle);
    ((dt.saturating_sub(di)) as f64 / dt as f64) * 100.0
}

fn meminfo() -> (f64, f64) {
    let Ok(s) = fs::read_to_string("/proc/meminfo") else { return (0.0, 0.0) };
    let kv = |k: &str| -> f64 {
        s.lines()
            .find(|l| l.starts_with(k))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|v| v.parse::<f64>().ok())
            .unwrap_or(0.0)
    };
    let total = kv("MemTotal:");
    let avail = kv("MemAvailable:");
    let swap_total = kv("SwapTotal:");
    let swap_free = kv("SwapFree:");
    let mem_pct = if total > 0.0 { (total - avail) / total * 100.0 } else { 0.0 };
    let swap_pct = if swap_total > 0.0 { (swap_total - swap_free) / swap_total * 100.0 } else { 0.0 };
    (mem_pct, swap_pct)
}

// PSI is the number that actually predicts a stall, and no stock KSysGuard
// sensor exposes it — /proc/pressure has no KSystemStats backend, which is why
// the old top panel faked it with diskusage widgets pointed at pressure paths
// and mislabelled titles. Read it directly instead.
//
// BOTH lines, because the panel this replaces displayed both: one widget
// carried pressure/{cpu,io,memory}/some10Sec and another carried the full10Sec
// variants. `some` is "at least one task stalled", `full` is "every task
// stalled" — on a box that thrashes, full is the one that means the machine
// stopped, so dropping it would lose the more alarming number.
fn pressure(kind: &str, line: &str, window: &str) -> f64 {
    fs::read_to_string(format!("/proc/pressure/{kind}"))
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with(line))?
                .split_whitespace()
                .find_map(|f| f.strip_prefix(window)?.parse::<f64>().ok())
        })
        .unwrap_or(0.0)
}

/// One kind's full picture: some/full across all three windows the kernel
/// keeps. The panel shows avg10 as the live bar and avg60 as the "1 min"
/// reading, and there is no cost to publishing avg300 alongside.
fn pressure_block(kind: &str) -> String {
    let g = |l: &str, w: &str| pressure(kind, l, w);
    format!(
        "{{\"some10\":{:.2},\"some60\":{:.2},\"some300\":{:.2},\
          \"full10\":{:.2},\"full60\":{:.2},\"full300\":{:.2}}}",
        g("some", "avg10="), g("some", "avg60="), g("some", "avg300="),
        g("full", "avg10="), g("full", "avg60="), g("full", "avg300=")
    )
}

/// Top processes by RSS, for the expanded view's killable table. Read straight
/// from /proc rather than forking ps every 2s — this runs forever.
fn top_procs(n: usize) -> String {
    let mut v: Vec<(u64, i32, String)> = Vec::new();
    let Ok(rd) = fs::read_dir("/proc") else { return "[]".into() };
    for e in rd.flatten() {
        let name = e.file_name();
        let Some(nm) = name.to_str() else { continue };
        let Ok(pid) = nm.parse::<i32>() else { continue };
        let Ok(st) = fs::read_to_string(format!("/proc/{pid}/status")) else { continue };
        let rss = st
            .lines()
            .find(|l| l.starts_with("VmRSS:"))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|x| x.parse::<u64>().ok())
            .unwrap_or(0);
        if rss == 0 {
            continue;
        }
        let comm = st
            .lines()
            .find(|l| l.starts_with("Name:"))
            .and_then(|l| l.split_whitespace().nth(1))
            .unwrap_or("?")
            .to_string();
        v.push((rss, pid, comm));
    }
    v.sort_unstable_by(|a, b| b.0.cmp(&a.0));
    v.truncate(n);
    let items: Vec<String> = v
        .iter()
        .map(|(rss, pid, comm)| {
            // Escape the name: a process can be called anything, and one quote
            // in it would make the whole snapshot unparseable.
            let safe: String = comm.chars().filter(|c| c.is_alphanumeric() || "-_.".contains(*c)).collect();
            format!("{{\"pid\":{pid},\"rss\":{:.0},\"name\":\"{safe}\"}}", *rss as f64 / 1024.0)
        })
        .collect();
    format!("[{}]", items.join(","))
}

// Disk throughput, matching the panel's disk/all/read + disk/all/write.
// /proc/diskstats is cumulative sectors since boot, so this needs the same
// two-sample treatment as CPU. Sectors are 512 bytes by kernel convention
// regardless of the device's physical block size.
#[derive(Default, Clone, Copy)]
struct DiskTotals {
    read_sectors: u64,
    write_sectors: u64,
}

fn read_diskstats() -> DiskTotals {
    let Ok(s) = fs::read_to_string("/proc/diskstats") else { return DiskTotals::default() };
    let mut t = DiskTotals::default();
    for l in s.lines() {
        let f: Vec<&str> = l.split_whitespace().collect();
        if f.len() < 10 {
            continue;
        }
        // Skip partitions and virtual devices, or every byte is counted twice
        // (once for sda, again for sda1). Whole disks only.
        //
        // "last char is a digit" picks out sda1/sdb2 partitions on SCSI/SATA
        // disks, where the whole-disk name (sda) has none. But nvme and mmc
        // devices number the *disk* too (nvme0n1, mmcblk0) and only append a
        // 'p' before the partition digit (nvme0n1p1, mmcblk0p1) — this box is
        // a Surface, so its NVMe/eMMC disk would otherwise be silently
        // excluded and every disk widget would read zero forever.
        let name = f[2];
        if name.starts_with("loop") || name.starts_with("ram") || name.starts_with("dm-") {
            continue;
        }
        if name.starts_with("nvme") || name.starts_with("mmcblk") {
            if name.contains('p') {
                continue; // nvme0n1p1, mmcblk0p1
            }
        } else if name.chars().last().is_some_and(|c| c.is_ascii_digit()) {
            continue; // sda1, sdb2, …
        }
        t.read_sectors += f[5].parse::<u64>().unwrap_or(0);
        t.write_sectors += f[9].parse::<u64>().unwrap_or(0);
    }
    t
}

fn disk_rate_mb(prev: DiskTotals, now: DiskTotals, secs: f64) -> (f64, f64) {
    if secs <= 0.0 {
        return (0.0, 0.0);
    }
    let b = |a: u64, b: u64| (a.saturating_sub(b) as f64 * 512.0) / 1_048_576.0 / secs;
    (b(now.read_sectors, prev.read_sectors), b(now.write_sectors, prev.write_sectors))
}

// Network throughput, both directions, summed across real interfaces.
// /proc/net/dev is cumulative bytes, so same two-sample treatment as cpu/disk.
#[derive(Default, Clone, Copy)]
struct NetTotals {
    rx: u64,
    tx: u64,
}

fn read_net() -> NetTotals {
    let Ok(s) = fs::read_to_string("/proc/net/dev") else { return NetTotals::default() };
    let mut t = NetTotals::default();
    for l in s.lines().skip(2) {
        let Some((name, rest)) = l.split_once(':') else { continue };
        let name = name.trim();
        // Loopback would double every local connection, and the virtual
        // bridges docker/wireguard create carry traffic already counted on the
        // physical interface it leaves by.
        if name == "lo" || name.starts_with("veth") || name.starts_with("br-") || name.starts_with("docker") {
            continue;
        }
        let f: Vec<&str> = rest.split_whitespace().collect();
        t.rx += f.first().and_then(|x| x.parse::<u64>().ok()).unwrap_or(0);
        t.tx += f.get(8).and_then(|x| x.parse::<u64>().ok()).unwrap_or(0);
    }
    t
}

fn net_rate_mb(prev: NetTotals, now: NetTotals, secs: f64) -> (f64, f64) {
    if secs <= 0.0 {
        return (0.0, 0.0);
    }
    let r = |a: u64, b: u64| (a.saturating_sub(b) as f64) / 1_048_576.0 / secs;
    (r(now.rx, prev.rx), r(now.tx, prev.tx))
}

// Load average — the one number that is already an average, so it needs no
// sampling state and says something the instantaneous percentages cannot:
// how many tasks wanted a CPU, including the ones that never got one.
fn loadavg() -> (f64, f64, f64) {
    fs::read_to_string("/proc/loadavg")
        .ok()
        .map(|s| {
            let f: Vec<f64> = s.split_whitespace().take(3).filter_map(|x| x.parse().ok()).collect();
            (
                f.first().copied().unwrap_or(0.0),
                f.get(1).copied().unwrap_or(0.0),
                f.get(2).copied().unwrap_or(0.0),
            )
        })
        .unwrap_or((0.0, 0.0, 0.0))
}

// The user slice's cap is what actually decides who gets OOM-killed on this
// box — the machine has more RAM than the slice is allowed to use, so free(1)
// reads healthy while the session is being reaped. Publish both numbers.
fn slice_mem() -> (f64, f64) {
    let uid = current_uid();
    let base = format!("/sys/fs/cgroup/user.slice/user-{uid}.slice");
    let read = |f: &str| -> f64 {
        fs::read_to_string(format!("{base}/{f}"))
            .ok()
            .and_then(|s| s.trim().parse::<f64>().ok())
            .unwrap_or(0.0)
    };
    (read("memory.current") / 1_073_741_824.0, read("memory.max") / 1_073_741_824.0)
}

// Read from /proc/self/status rather than libc::getuid(): the uid is needed to
// build a cgroup path, and a path that silently points at the wrong slice is
// worse than one that fails loudly. This way the fallback is explicit.
fn current_uid() -> u32 {
    fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("Uid:"))?
                .split_whitespace()
                .nth(1)?
                .parse()
                .ok()
        })
        .unwrap_or(1000)
}

// Root filesystem fullness, matching the panel's disk/all/total widget.
// Rust std has no statvfs, so this goes through libc — one FFI call every 2s
// is cheaper than forking df, which is the only alternative that does not
// involve reimplementing filesystem-specific superblock parsing.
fn disk_root_percent() -> f64 {
    let path = std::ffi::CString::new("/").unwrap();
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(path.as_ptr(), &mut st) } != 0 {
        return 0.0;
    }
    let total = st.f_blocks as f64;
    if total <= 0.0 {
        return 0.0;
    }
    // f_bavail, not f_bfree: the reserved-for-root blocks are not space the
    // user can use, and df reports the same way.
    let used = total - st.f_bavail as f64;
    (used / total) * 100.0
}

// Battery — read straight from sysfs, never upowerd. On the Surface Pro 8 the
// SAM controller intermittently reports voltage_now=0, which sends upowerd's
// percentage math to NaN and its threshold actions silently stop firing —
// battery-watchdog.service (aa_desk-usr .../configuration_system-protection-
// battery.nix) exists on the privileged side for exactly that reason, with a
// multi-voter design to survive a frozen gauge. This reader is READ-ONLY: it
// publishes what sysfs says so the panel can show it, and does NOT decide to
// hibernate — that stays the sole job of the systemd-side watchdog, which is
// already the single choke point session-checkpoint-hibernate.service and
// hibernate-preflight are wired to (see configuration_session-checkpoint.nix,
// configuration_pre-hibernate-warning.nix). A second trigger here, running
// unprivileged in the tray daemon, would race the existing one instead of
// replacing it — worse than the one path that exists today.
struct BatteryReading {
    present: bool,
    pct: f64,
    status: String,
    minutes_left: Option<f64>,
}

fn find_battery_dir() -> Option<PathBuf> {
    let rd = fs::read_dir("/sys/class/power_supply").ok()?;
    for e in rd.flatten() {
        let name = e.file_name();
        let Some(nm) = name.to_str() else { continue };
        if nm.starts_with("BAT") {
            return Some(e.path());
        }
    }
    None
}

/// `None` means no battery directory at all (desktop). `Some(present=false)`
/// means the dir exists but the kernel currently reports no cell attached
/// (present flips transiently on some hardware) — the panel should show
/// "no battery" rather than stale numbers either way.
fn read_battery() -> Option<BatteryReading> {
    let dir = find_battery_dir()?;
    let read = |f: &str| -> Option<String> {
        fs::read_to_string(dir.join(f)).ok().map(|s| s.trim().to_string())
    };
    let present = read("present").and_then(|s| s.parse::<i32>().ok()).unwrap_or(1) != 0;
    if !present {
        return Some(BatteryReading { present: false, pct: 0.0, status: "Absent".into(), minutes_left: None });
    }
    let pct = read("capacity").and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0);
    let status = read("status").unwrap_or_else(|| "Unknown".into());
    // Time-to-empty only when discharging AND power_now is known and
    // strictly positive. This is the divide-by-zero guard: a zero or
    // missing power_now (SAM freeze, AC just unplugged, no reading yet)
    // must produce "unknown", never a NaN/Infinity that would break the
    // widget's JSON.parse and take the whole panel down with it.
    let power_now = read("power_now").and_then(|s| s.parse::<f64>().ok());
    let energy_now = read("energy_now").and_then(|s| s.parse::<f64>().ok());
    let minutes_left = match (status.as_str(), power_now, energy_now) {
        ("Discharging", Some(p), Some(e)) if p > 0.0 && e >= 0.0 => {
            let m = e / p * 60.0;
            if m.is_finite() { Some(m) } else { None }
        }
        _ => None,
    };
    Some(BatteryReading { present: true, pct, status, minutes_left })
}

/// Battery block of the snapshot JSON. `null` when there is no battery at
/// all (desktop) so the widget can tell "no battery" apart from "battery
/// present but reading unavailable".
fn battery_json(b: &Option<BatteryReading>) -> String {
    let Some(b) = b else { return "null".into() };
    if !b.present {
        return "{\"present\":false}".into();
    }
    // status comes straight from the kernel (Charging/Discharging/Full/Not
    // charging/Unknown) — no free-form text, but strip quotes defensively
    // rather than trust sysfs never to hand back something that breaks JSON.
    let status: String = b.status.chars().filter(|c| *c != '"' && *c != '\\').collect();
    let minutes = match b.minutes_left {
        Some(m) => format!("{m:.0}"),
        None => "null".into(),
    };
    format!(
        "{{\"present\":true,\"pct\":{:.0},\"status\":\"{status}\",\"charging\":{},\"minutes_left\":{minutes}}}",
        b.pct,
        status == "Charging",
    )
}

/// Serialise one sample. Hand-rolled rather than serde_json: it is a fixed
/// shape written every 2s and read by QML's JSON.parse, and the whole point of
/// this file is that the machine is measured once and cheaply.
#[allow(clippy::too_many_arguments)]
fn render(
    cpu: f64, cores: &[f64],
    mem: f64, swap: f64,
    disk: f64, disk_r: f64, disk_w: f64,
    net_rx: f64, net_tx: f64,
    load1: f64, load5: f64, load15: f64,
    slice_cur: f64, slice_max: f64,
    battery: &Option<BatteryReading>,
    procs: &str,
) -> String {
    let core_list: Vec<String> = cores.iter().map(|c| format!("{c:.1}")).collect();
    let mut s = String::with_capacity(1024);
    let _ = write!(
        s,
        "{{\"cpu\":{cpu:.1},\"cores\":[{}],\
          \"mem\":{mem:.1},\"swap\":{swap:.1},\
          \"disk\":{disk:.1},\"disk_r\":{disk_r:.2},\"disk_w\":{disk_w:.2},\
          \"net_rx\":{net_rx:.2},\"net_tx\":{net_tx:.2},\
          \"load1\":{load1:.2},\"load5\":{load5:.2},\"load15\":{load15:.2},\
          \"psi\":{{\"cpu\":{},\"io\":{},\"memory\":{}}},\
          \"slice_gib\":{slice_cur:.2},\"slice_max_gib\":{slice_max:.2},\
          \"battery\":{},\
          \"procs\":{procs},\"ts\":{}}}",
        core_list.join(","),
        pressure_block("cpu"),
        pressure_block("io"),
        pressure_block("memory"),
        battery_json(battery),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    );
    s
}

/// Signals the panel's process table may send. Not just SIGTERM/SIGKILL: a
/// process table that can only destroy is a blunt instrument, and the reason
/// this one exists is a machine that thrashes — STOP/CONT to freeze a runaway
/// without losing its state is often the right first move, and HUP is how you
/// tell a daemon to reload rather than die.
fn signal_by_name(name: &str) -> Option<i32> {
    Some(match name {
        "TERM" => libc::SIGTERM, // ask politely; the default
        "KILL" => libc::SIGKILL, // unignorable, unmaskable, no cleanup
        "INT"  => libc::SIGINT,  // as if Ctrl-C
        "HUP"  => libc::SIGHUP,  // reload for daemons, hangup for the rest
        "QUIT" => libc::SIGQUIT, // terminate + core dump
        "STOP" => libc::SIGSTOP, // freeze without killing — unignorable
        "CONT" => libc::SIGCONT, // resume a stopped one
        "USR1" => libc::SIGUSR1, // application-defined
        _ => return None,
    })
}

/// A signal requested from the panel. QML cannot signal a process, and giving a
/// widget an exec path is worse than giving the daemon a mailbox: the daemon
/// already runs as this user, so it can only ever signal what the user could.
/// Each line is "<pid> <SIG>"; the file is consumed on read, so a stale request
/// cannot fire twice.
fn drain_kill_requests() {
    let Some(dir) = std::env::var_os("XDG_RUNTIME_DIR") else { return };
    let req = PathBuf::from(&dir).join("my-konsole-watchdog.kill");
    let Ok(body) = fs::read_to_string(&req) else { return };
    let _ = fs::remove_file(&req);
    for line in body.lines() {
        let mut it = line.split_whitespace();
        let Some(Ok(pid)) = it.next().map(|x| x.parse::<i32>()) else { continue };
        let sig = it.next().unwrap_or("TERM");
        let Some(signum) = signal_by_name(sig) else {
            eprintln!("[watchdog] unknown signal {sig:?} — ignored");
            continue;
        };
        // Never signal init or ourselves. kill(2) already stops us reaching
        // another user's processes; this stops the panel stopping the thing
        // that feeds it, which would leave the widget frozen and blameless.
        if pid <= 1 || pid == std::process::id() as i32 {
            eprintln!("[watchdog] refusing to signal pid {pid}");
            continue;
        }
        unsafe { libc::kill(pid, signum) };
        eprintln!("[watchdog] SIG{sig} -> pid {pid} (requested from panel)");
    }
}

/// Publish atomically — a widget polling on its own timer must never read a
/// half-written file. Write to a sibling temp then rename(2), same as the
/// status line's publisher.
fn publish(path: &PathBuf, body: &str) {
    let tmp = path.with_extension("tmp");
    if fs::write(&tmp, body).is_ok() {
        let _ = fs::rename(&tmp, path);
    }
}

/// Runs forever on its own thread. Started only in --tray-daemon mode, so the
/// GUI process never duplicates it — the same rule the tray icons follow after
/// registering them from both processes produced sixteen of eight.
pub fn spawn() {
    let Some(path) = snapshot_path() else {
        eprintln!("[watchdog] no XDG_RUNTIME_DIR — not publishing metrics");
        return;
    };
    std::thread::spawn(move || {
        let (mut prev, mut prev_cores) = read_cpu_all();
        let mut prev_disk = read_diskstats();
        let mut prev_net = read_net();
        loop {
            std::thread::sleep(std::time::Duration::from_millis(INTERVAL_MS));
            drain_kill_requests();

            let (now, now_cores) = read_cpu_all();
            let cpu = cpu_percent(prev, now);
            let cores: Vec<f64> = now_cores
                .iter()
                .zip(prev_cores.iter().chain(std::iter::repeat(&CpuTotals::default())))
                .map(|(n, p)| cpu_percent(*p, *n))
                .collect();
            prev = now;
            prev_cores = now_cores;

            let now_disk = read_diskstats();
            let (disk_r, disk_w) = disk_rate_mb(prev_disk, now_disk, INTERVAL_MS as f64 / 1000.0);
            prev_disk = now_disk;

            let now_net = read_net();
            let (net_rx, net_tx) = net_rate_mb(prev_net, now_net, INTERVAL_MS as f64 / 1000.0);
            prev_net = now_net;
            let (load1, load5, load15) = loadavg();

            let (mem, swap) = meminfo();
            let (slice_cur, slice_max) = slice_mem();
            let body = render(
                cpu, &cores, mem, swap,
                disk_root_percent(), disk_r, disk_w,
                net_rx, net_tx,
                load1, load5, load15,
                slice_cur, slice_max,
                &read_battery(),
                &top_procs(12),
            );
            publish(&path, &body);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    // The whole point is a percentage from two cumulative samples; getting the
    // idle/total arithmetic backwards would show a busy machine as idle.
    #[test]
    fn cpu_percent_is_busy_fraction_between_samples() {
        let a = CpuTotals { idle: 100, total: 200 };
        let b = CpuTotals { idle: 150, total: 350 }; // +50 idle of +150 total
        let p = cpu_percent(a, b);
        assert!((p - 66.6).abs() < 0.5, "expected ~66.7% busy, got {p}");
        // No time passed => no division by zero, and no fake 100%.
        assert_eq!(cpu_percent(a, a), 0.0);
    }

    // Disk throughput is cumulative sectors, same trap as CPU: a wrong delta
    // shows an idle disk as saturated or vice versa.
    #[test]
    fn disk_rate_is_bytes_per_second_between_samples() {
        let a = DiskTotals { read_sectors: 0, write_sectors: 0 };
        let b = DiskTotals { read_sectors: 2048, write_sectors: 4096 }; // 1MiB / 2MiB
        let (r, w) = disk_rate_mb(a, b, 2.0);
        assert!((r - 0.5).abs() < 0.01, "expected 0.5 MB/s read, got {r}");
        assert!((w - 1.0).abs() < 0.01, "expected 1.0 MB/s write, got {w}");
        assert_eq!(disk_rate_mb(a, b, 0.0), (0.0, 0.0));
    }

    #[test]
    fn render_is_parseable_json_with_every_field() {
        let s = render(12.5, &[10.0, 20.0, 30.0, 40.0], 40.0, 1.0,
                       55.0, 1.5, 2.5, 0.3, 0.4, 1.1, 2.2, 3.3, 4.9, 5.6,
                       &None, "[]");
        for k in ["cpu", "cores", "mem", "swap", "disk", "disk_r", "disk_w",
                  "net_rx", "net_tx", "load1", "load5", "load15",
                  "psi", "slice_gib", "slice_max_gib", "battery", "procs", "ts"] {
            assert!(s.contains(&format!("\"{k}\":")), "missing {k} in {s}");
        }
        assert!(s.starts_with('{') && s.ends_with('}'), "not an object: {s}");
    }

    // No battery at all (desktop) must render valid `null`, not an absent key
    // or a panic — the widget branches on this to hide the battery cluster.
    #[test]
    fn battery_json_is_null_when_no_battery_present() {
        assert_eq!(battery_json(&None), "null");
    }

    // The whole point of this reader: a zero or missing power_now (SAM
    // freeze, just-unplugged, charging) must never reach a division — it
    // must come out as JSON `null`, never NaN/Infinity, which is not valid
    // JSON and would break the widget's JSON.parse for every field, not
    // just battery.
    #[test]
    fn minutes_left_is_null_not_nan_when_rate_is_zero_or_absent() {
        let zero_rate = BatteryReading {
            present: true, pct: 40.0, status: "Discharging".into(), minutes_left: None,
        };
        let j = battery_json(&Some(zero_rate));
        assert!(j.contains("\"minutes_left\":null"), "expected null minutes_left, got {j}");
        assert!(!j.contains("NaN") && !j.contains("Infinity"), "invalid JSON literal in {j}");

        // Charging (rate direction doesn't apply) also renders a clean null.
        let charging = BatteryReading {
            present: true, pct: 80.0, status: "Charging".into(), minutes_left: None,
        };
        let j2 = battery_json(&Some(charging));
        assert!(j2.contains("\"charging\":true"));
        assert!(j2.contains("\"minutes_left\":null"));
    }

    // A real, finite estimate must serialise as a plain number the widget
    // can format directly.
    #[test]
    fn minutes_left_serialises_as_a_finite_number_when_known() {
        let r = BatteryReading {
            present: true, pct: 55.0, status: "Discharging".into(), minutes_left: Some(123.4),
        };
        let j = battery_json(&Some(r));
        assert!(j.contains("\"minutes_left\":123"), "expected ~123 in {j}");
    }
}
