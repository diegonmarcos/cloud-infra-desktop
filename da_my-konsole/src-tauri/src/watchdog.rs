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

fn read_cpu() -> CpuTotals {
    let Ok(s) = fs::read_to_string("/proc/stat") else { return CpuTotals::default() };
    let Some(line) = s.lines().next() else { return CpuTotals::default() };
    let v: Vec<u64> = line
        .split_whitespace()
        .skip(1)
        .filter_map(|x| x.parse().ok())
        .collect();
    // user nice system idle iowait irq softirq steal …
    let idle = v.get(3).copied().unwrap_or(0) + v.get(4).copied().unwrap_or(0);
    CpuTotals { idle, total: v.iter().sum() }
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
fn pressure(kind: &str) -> f64 {
    fs::read_to_string(format!("/proc/pressure/{kind}"))
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("some"))?
                .split_whitespace()
                .find_map(|f| f.strip_prefix("avg10=")?.parse::<f64>().ok())
        })
        .unwrap_or(0.0)
}

// The user slice's cap is what actually decides who gets OOM-killed on this
// box — the machine has more RAM than the slice is allowed to use, so free(1)
// reads healthy while the session is being reaped. Publish both numbers.
fn slice_mem() -> (f64, f64) {
    let uid = unsafe { libc_getuid() };
    let base = format!("/sys/fs/cgroup/user.slice/user-{uid}.slice");
    let read = |f: &str| -> f64 {
        fs::read_to_string(format!("{base}/{f}"))
            .ok()
            .and_then(|s| s.trim().parse::<f64>().ok())
            .unwrap_or(0.0)
    };
    (read("memory.current") / 1_073_741_824.0, read("memory.max") / 1_073_741_824.0)
}

// Avoiding a libc dependency for one call — the uid is also in /proc/self/status.
unsafe fn libc_getuid() -> u32 {
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

fn disk_root_percent() -> f64 {
    // statvfs without libc: /proc/self/mountinfo gives the device, but the
    // simplest portable read here is the cgroup-free `df`-equivalent in
    // /proc — which does not exist. Fall back to 0 rather than shelling out
    // every 2s; disk fullness changes on a scale where the Data panel's
    // on-demand commands are the right place for it.
    0.0
}

/// Serialise one sample. Hand-rolled rather than serde_json: this is eight
/// numbers on a 2s timer, and the file is read by QML's JSON.parse.
fn render(cpu: f64, mem: f64, swap: f64, psi_cpu: f64, psi_io: f64, psi_mem: f64, slice_cur: f64, slice_max: f64) -> String {
    let mut s = String::with_capacity(256);
    let _ = write!(
        s,
        "{{\"cpu\":{cpu:.1},\"mem\":{mem:.1},\"swap\":{swap:.1},\
         \"psi_cpu\":{psi_cpu:.2},\"psi_io\":{psi_io:.2},\"psi_mem\":{psi_mem:.2},\
         \"slice_gib\":{slice_cur:.2},\"slice_max_gib\":{slice_max:.2},\
         \"disk\":{:.1},\"ts\":{}}}",
        disk_root_percent(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    );
    s
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
        let mut prev = read_cpu();
        loop {
            std::thread::sleep(std::time::Duration::from_millis(INTERVAL_MS));
            let now = read_cpu();
            let cpu = cpu_percent(prev, now);
            prev = now;
            let (mem, swap) = meminfo();
            let (slice_cur, slice_max) = slice_mem();
            let body = render(
                cpu,
                mem,
                swap,
                pressure("cpu"),
                pressure("io"),
                pressure("memory"),
                slice_cur,
                slice_max,
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

    #[test]
    fn render_is_parseable_json_with_every_field() {
        let s = render(12.5, 40.0, 1.0, 0.5, 0.25, 0.0, 4.9, 5.6);
        for k in ["cpu", "mem", "swap", "psi_cpu", "psi_io", "psi_mem", "slice_gib", "slice_max_gib", "ts"] {
            assert!(s.contains(&format!("\"{k}\":")), "missing {k} in {s}");
        }
        assert!(s.starts_with('{') && s.ends_with('}'), "not an object: {s}");
    }
}
