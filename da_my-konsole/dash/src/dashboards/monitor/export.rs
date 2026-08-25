// Writing a snapshot out, and the /proc reads only the detail view needs.
use std::fs;

use serde_json::Value;

use super::data::{arr, num, text};
use super::fmt::{fmt_bytes_short, fmt_g, fmt_gib, fmt_uptime};

/// Everything on screen, written out twice: the snapshot verbatim as JSON and
/// a readable report as Markdown.
///
/// Both, not one. The JSON is the truth and survives being diffed against a
/// later export or fed to something else; the Markdown is what you can paste
/// into an issue at 3am without the reader parsing a thousand-line object.
/// Writing only the pretty one is how exports stop being useful the moment
/// somebody needs a field it left out.
///
/// The name is {host}-{user}-{timestamp}: the triple that stays unambiguous
/// once you have exported the same peer twice and a second machine once. The
/// host comes from the SNAPSHOT, so exporting a peer names the peer.
pub(crate) fn export_snapshot(s: &Value, target: Option<String>) -> Result<String, String> {
    let hi = |k: &str| text(s, &format!("host_info.{k}"));
    let host = if hi("host").is_empty() { "unknown".to_string() } else { hi("host") };
    let user = if hi("user").is_empty() { "unknown".to_string() } else { hi("user") };
    // date(1) rather than arithmetic on a unix counter: this name is for a
    // human to find later, so it wants LOCAL time, and those rules live in the
    // system's timezone database rather than in a formula worth rewriting.
    let stamp = std::process::Command::new("date")
        .arg("+%Y-%m-%d_%H-%M-%S")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|x| x.trim().to_string())
        .filter(|x| !x.is_empty())
        .ok_or("could not read the clock")?;

    let safe = |x: &str| -> String {
        x.chars()
            .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
            .collect()
    };
    let dir = std::env::var("HOME").map_err(|_| "no HOME".to_string())?;
    let stem = format!("{dir}/{}-{}-{stamp}", safe(&host), safe(&user));

    let json = serde_json::to_string_pretty(s).map_err(|e| e.to_string())?;
    fs::write(format!("{stem}.json"), json).map_err(|e| format!("{stem}.json: {e}"))?;

    let n = |k: &str| num(s, k);
    let mut m = String::new();
    m.push_str(&format!("# {host} · {stamp}\n\n"));
    if let Some(a) = &target {
        m.push_str(&format!(
            "> Collected from `{a}` over ssh by the hub, not published by that machine.\n\n"
        ));
    }
    let row = |m: &mut String, k: &str, v: String| m.push_str(&format!("| {k} | {v} |\n"));
    m.push_str("| | |\n|---|---|\n");
    row(&mut m, "user", user.clone());
    row(&mut m, "os", hi("os"));
    row(&mut m, "kernel", hi("kernel"));
    row(&mut m, "uptime", fmt_uptime(n("totals.since_s")));
    row(&mut m, "cpu", text(s, "cpu_info.model"));
    row(&mut m, "cores", format!("{}", arr(s, "cores").len()));
    row(&mut m, "memory", fmt_gib(n("mem_detail.total")));
    row(&mut m, "swap", fmt_gib(n("swap_detail.total")));

    m.push_str("\n## Now\n\n| | |\n|---|---|\n");
    row(&mut m, "cpu", format!("{:.1}%", n("cpu")));
    row(&mut m, "load", format!("{:.2} {:.2} {:.2}", n("load1"), n("load5"), n("load15")));
    row(
        &mut m,
        "memory",
        format!("{:.1}%  {} of {}", n("mem"), fmt_gib(n("mem_detail.used")), fmt_gib(n("mem_detail.total"))),
    );
    row(&mut m, "swap", format!("{:.1}%", n("swap")));
    row(
        &mut m,
        "psi cpu / io / mem",
        format!("{:.2} / {:.2} / {:.2}", n("psi.cpu.some10"), n("psi.io.full10"), n("psi.memory.full10")),
    );

    m.push_str("\n## Moved since boot\n\n| | |\n|---|---|\n");
    for (k, f) in [
        ("downloaded", "totals.net_rx_bytes"),
        ("uploaded", "totals.net_tx_bytes"),
        ("read", "totals.disk_read_bytes"),
        ("written", "totals.disk_write_bytes"),
    ] {
        row(&mut m, k, fmt_bytes_short(n(f)));
    }

    let ifs = arr(s, "host_info.ifaces");
    if !ifs.is_empty() {
        m.push_str("\n## Network\n\n| interface | address |\n|---|---|\n");
        for i in ifs {
            m.push_str(&format!("| {} | {} |\n", text(i, "name"), text(i, "addr")));
        }
        let pubip = hi("public");
        m.push_str(&format!(
            "\ngateway `{}` via `{}` · public {} · dns {}\n",
            hi("gateway"),
            hi("wan_if"),
            if pubip.is_empty() { "behind NAT".into() } else { format!("`{pubip}`") },
            arr(s, "host_info.dns")
                .iter()
                .filter_map(|d| d.as_str())
                .map(|d| format!("`{d}`"))
                .collect::<Vec<_>>()
                .join(" ")
        ));
    }

    for pool in arr(s, "storage") {
        m.push_str(&format!(
            "\n## Storage ({})\n\n{} of {} used\n\n| mount | used | limit |\n|---|---|---|\n",
            text(pool, "label"),
            fmt_g(num(pool, "alloc_used")),
            fmt_g(num(pool, "dev_size"))
        ));
        for v in arr(pool, "volumes") {
            let lim = num(v, "limit");
            m.push_str(&format!(
                "| {} | {} | {} |\n",
                text(v, "mount"),
                fmt_g(num(v, "referenced")),
                if lim > 0.0 { fmt_g(lim) } else { "—".into() }
            ));
        }
    }

    let cs = arr(s, "containers");
    if !cs.is_empty() {
        m.push_str("\n## Containers\n\n| name | status | cpu | mem | ports | image |\n|---|---|---|---|---|---|\n");
        for c in cs {
            let or = |k: &str| {
                let v = text(c, k);
                if v.is_empty() { "—".to_string() } else { v }
            };
            m.push_str(&format!(
                "| {} | {} | {} | {} | {} | {} |\n",
                text(c, "name"),
                text(c, "status"),
                or("cpu"),
                or("mem_pct"),
                or("ports"),
                text(c, "image")
            ));
        }
    }

    m.push_str("\n## Processes\n\n| pid | user | name | cpu% | mem% | rss |\n|---|---|---|---|---|---|\n");
    for p in arr(s, "proc_table").iter().take(40) {
        m.push_str(&format!(
            "| {} | {} | {} | {:.1} | {:.2} | {} |\n",
            num(p, "pid") as i64,
            text(p, "user"),
            text(p, "name"),
            num(p, "cpu_pct"),
            num(p, "mem_pct"),
            fmt_bytes_short(num(p, "mem_rss_bytes"))
        ));
    }
    m.push_str("\n<sub>my-konsole-dash · the JSON beside this file is the same snapshot in full.</sub>\n");
    fs::write(format!("{stem}.md"), m).map_err(|e| format!("{stem}.md: {e}"))?;

    Ok(stem)
}

/// A pid's name straight from /proc, for when it has dropped out of the
/// published table but the process itself is still there.
pub(crate) fn proc_comm(pid: i32) -> Option<String> {
    fs::read_to_string(format!("/proc/{pid}/status"))
        .ok()?
        .lines()
        .find(|l| l.starts_with("Name:"))
        .map(|l| l[5..].trim().to_string())
}

pub(crate) fn exe_dir(pid: i32) -> Option<String> {
    let exe = fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    Some(exe.parent()?.display().to_string())
}

/// Hand a directory to the desktop's file manager.
///
/// stdio is nulled deliberately: xdg-open's helpers write to stderr, and this
/// process owns an alternate screen — one stray line from a child repaints as
/// corruption the user has to redraw to clear.
pub(crate) fn open_dir(dir: &str) -> Result<(), String> {
    std::process::Command::new("xdg-open")
        .arg(dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

