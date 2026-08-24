// Monitor — btop's UI, drawn from the my-konsole watchdog snapshot.
//
// WHY THIS READS A FILE INSTEAD OF SAMPLING
// The previous version ran sysinfo::System::refresh_all() plus shellouts to df
// and /proc/net/dev on every tick — a second full sampler competing with the
// tray daemon that already samples this machine every 2s and publishes
// $XDG_RUNTIME_DIR/my-konsole-watchdog.json. That duplication is exactly what
// makes glances cost 20-24% CPU here for numbers something else already has.
// This box collects nothing: one read per tick, then draw.
//
// It also gets data a TUI sampler would not have: the daemon keeps 10s/1m/5m/15m
// rolling averages and run-queue wait PER PROCESS (the `w` key cycles them, and
// the C10s/C60s/M10s/M60s columns show two of them beside the live value and
// are sortable in their own right),
// and freeze-guard publishes its own PSI voter state to /run/freeze-guard.json,
// so the PSI box can show not just pressure but which voters are armed.
//
// The kill path is the daemon's, not ours: a request is a "<pid> <SIG>" line
// appended to my-konsole-watchdog.kill, and the daemon enforces the protected
// slices. What this UI does with `protected` is a courtesy (dim the row, say
// why) — it is not the safety boundary and must never be treated as one.
//
// NOTE ON SELECTING TEXT: no mouse capture is enabled anywhere in this crate,
// which is deliberate — it is why you can drag-select and copy out of this
// dashboard the way you can in glances but cannot in btop.
use std::fs;
use std::io::Write as _;

use crossterm::event::KeyCode;
use ratatui::layout::{Alignment, Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Cell, Clear, Paragraph, Row, Table};
use ratatui::Frame;
use serde_json::Value;

use crate::frame::Dashboard;

const HIST: usize = 480; // enough samples for a very wide braille graph (2/col)

// ─────────────────────────────── snapshot access ───────────────────────────────

/// Dotted-path lookup. The snapshot's schema is broad and grows on the daemon
/// side; mirroring it as structs would mean a compile break every time a field
/// is added, so this reads Values defensively and returns a neutral 0 / "" for
/// anything missing. A dashboard must never blank out because one key moved.
fn num(v: &Value, path: &str) -> f64 {
    let mut cur = v;
    for k in path.split('.') {
        match cur.get(k) {
            Some(n) => cur = n,
            None => return 0.0,
        }
    }
    cur.as_f64().unwrap_or(0.0)
}

fn text(v: &Value, path: &str) -> String {
    let mut cur = v;
    for k in path.split('.') {
        match cur.get(k) {
            Some(n) => cur = n,
            None => return String::new(),
        }
    }
    cur.as_str().unwrap_or("").to_string()
}

fn arr<'a>(v: &'a Value, path: &str) -> &'a [Value] {
    let mut cur = v;
    for k in path.split('.') {
        match cur.get(k) {
            Some(n) => cur = n,
            None => return &[],
        }
    }
    cur.as_array().map(|a| a.as_slice()).unwrap_or(&[])
}

fn snapshot_path() -> String {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".into());
    format!("{dir}/my-konsole-watchdog.json")
}

fn kill_path() -> String {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".into());
    format!("{dir}/my-konsole-watchdog.kill")
}

fn read_json(path: &str) -> Value {
    fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null)
}

fn now_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

// ───────────────────────────────── btop visuals ────────────────────────────────

/// btop's value gradient: green below, yellow through the middle, red at the
/// top. Used for BOTH the fill colour of a meter position and the vertical
/// colour of a graph row, which is what makes the two read as one language.
fn grad(f: f64) -> Color {
    let f = f.clamp(0.0, 1.0);
    let lerp = |a: f64, b: f64, t: f64| (a + (b - a) * t) as u8;
    if f < 0.5 {
        let t = f / 0.5;
        Color::Rgb(lerp(64.0, 240.0, t), lerp(220.0, 222.0, t), lerp(120.0, 64.0, t))
    } else {
        let t = (f - 0.5) / 0.5;
        Color::Rgb(lerp(240.0, 240.0, t), lerp(222.0, 72.0, t), lerp(64.0, 72.0, t))
    }
}

const DIM: Color = Color::Rgb(58, 62, 74);
const LABEL: Color = Color::Rgb(120, 128, 145);

/// btop's box: rounded corners, the title bracketed into the top border, and
/// the keys that act on that box parked in the bottom-right of its frame.
fn bbox(title: &str, hint: &str) -> Block<'static> {
    let mut b = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(DIM))
        .title(Line::from(vec![
            Span::styled("┤", Style::default().fg(DIM)),
            Span::styled(
                title.to_string(),
                Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
            ),
            Span::styled("├", Style::default().fg(DIM)),
        ]));
    if !hint.is_empty() {
        b = b.title_bottom(
            Line::from(Span::styled(format!("┤{hint}├"), Style::default().fg(DIM)))
                .alignment(Alignment::Right),
        );
    }
    b
}

/// btop's meter: a run of blocks whose colour comes from each POSITION along
/// the bar, not from the value — so a bar that is 80% full is green→yellow→red
/// across its own length, and the unfilled remainder stays dark.
fn meter(width: usize, frac: f64, label: &str) -> Line<'static> {
    let frac = frac.clamp(0.0, 1.0);
    let filled = (frac * width as f64).round() as usize;
    let mut spans: Vec<Span> = Vec::with_capacity(width + 2);
    for p in 0..width {
        if p < filled {
            spans.push(Span::styled("█", Style::default().fg(grad(p as f64 / width.max(1) as f64))));
        } else {
            spans.push(Span::styled("░", Style::default().fg(DIM)));
        }
    }
    if !label.is_empty() {
        spans.push(Span::raw(" "));
        spans.push(Span::styled(label.to_string(), Style::default().fg(Color::Gray)));
    }
    Line::from(spans)
}

// Braille cell dot bitmasks. A cell is 2 dots wide by 4 tall:
//     1 4
//     2 5
//     3 6
//     7 8
const LEFT: [u8; 4] = [0x01, 0x02, 0x04, 0x40];
const RIGHT: [u8; 4] = [0x08, 0x10, 0x20, 0x80];

/// btop's signature graph: braille gives 2x horizontal and 4x vertical
/// resolution over block characters, so an 8-row box holds 32 distinct levels
/// and a 60-column one holds 120 samples. Bottom-anchored area fill; each row
/// is coloured by its own height, so peaks go red without recolouring history.
fn braille_graph(data: &[f64], max: f64, cols: usize, rows: usize) -> Vec<Line<'static>> {
    if cols == 0 || rows == 0 {
        return vec![];
    }
    let want = cols * 2;
    let max = if max <= 0.0 { 1.0 } else { max };
    // Right-align history against the graph's right edge; pad the left with
    // zeroes so a freshly started dashboard grows in rather than stretching.
    let mut samples = vec![0.0f64; want];
    let have = data.len().min(want);
    for i in 0..have {
        samples[want - have + i] = data[data.len() - have + i];
    }
    let levels: Vec<usize> = samples
        .iter()
        .map(|v| (((v / max).clamp(0.0, 1.0)) * (rows * 4) as f64).round() as usize)
        .collect();

    let total = rows * 4;
    let mut out = Vec::with_capacity(rows);
    for r in 0..rows {
        let mut spans: Vec<Span> = Vec::with_capacity(cols);
        // Height fraction of this row's top edge drives its colour.
        let row_frac = (total - r * 4) as f64 / total as f64;
        let style = Style::default().fg(grad(row_frac));
        for c in 0..cols {
            let mut bits: u8 = 0;
            for (s, (&lm, &rm)) in LEFT.iter().zip(RIGHT.iter()).enumerate() {
                let height_from_bottom = total - (r * 4 + s);
                if levels[c * 2] >= height_from_bottom {
                    bits |= lm;
                }
                if levels[c * 2 + 1] >= height_from_bottom {
                    bits |= rm;
                }
            }
            let ch = char::from_u32(0x2800 + bits as u32).unwrap_or(' ');
            spans.push(Span::styled(ch.to_string(), style));
        }
        out.push(Line::from(spans));
    }
    out
}

fn push(v: &mut Vec<f64>, x: f64) {
    v.push(x);
    if v.len() > HIST {
        v.remove(0);
    }
}

/// A column of sizes only reads as a column if every entry is the same shape.
/// fmt_bytes_short gives "541.4M" next to "5.5M" next to "22.7G", which the
/// eye has to re-parse per row. This is always four digits and a unit, right
/// aligned with spaces: "  5M", " 541M", "1000M", "  19G". No decimals — at
/// four significant digits they never change a decision.
fn fmt_fixed(bytes: f64) -> String {
    let b = bytes.max(0.0);
    for (div, unit) in [(1.0, 'B'), (1024.0, 'K'), (1048576.0, 'M'), (1073741824.0, 'G')] {
        let n = (b / div).round();
        if n < 10000.0 {
            return format!("{n:>4.0}{unit}");
        }
    }
    format!("{:>4.0}T", b / 1099511627776.0)
}

fn fmt_gib(g: f64) -> String {
    if g >= 1.0 {
        format!("{g:.2}G")
    } else {
        format!("{:.0}M", g * 1024.0)
    }
}

fn fmt_rate_mb(mb: f64) -> String {
    if mb >= 1.0 {
        format!("{mb:.1}M/s")
    } else if mb >= 0.001 {
        format!("{:.0}K/s", mb * 1024.0)
    } else {
        "0".into()
    }
}

fn fmt_bps(b: f64) -> String {
    if b >= 1_048_576.0 {
        format!("{:.1}M", b / 1_048_576.0)
    } else if b >= 1024.0 {
        format!("{:.0}K", b / 1024.0)
    } else if b > 0.0 {
        format!("{b:.0}")
    } else {
        "·".into()
    }
}

fn fmt_bytes_short(b: f64) -> String {
    const U: [&str; 5] = ["B", "K", "M", "G", "T"];
    let mut v = b;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 { format!("{v:.0}{}", U[i]) } else { format!("{v:.1}{}", U[i]) }
}

fn fmt_uptime(secs: f64) -> String {
    let s = secs as u64;
    let (d, h, m) = (s / 86400, (s % 86400) / 3600, (s % 3600) / 60);
    if d > 0 { format!("{d}d {h:02}:{m:02}") } else { format!("{h:02}:{m:02}") }
}

// ─────────────────────────────── process table ────────────────────────────────

#[derive(Clone, Copy, PartialEq, Debug)]
enum Sort {
    Cpu,
    /// The four average columns rank on their own fixed window, independent of
    /// `w`. `w` retargets the live CPU%/MEM% columns; these four always mean
    /// what their header says, so "rank by C60s" is answerable without first
    /// putting the display into a particular mode.
    C10s,
    C60s,
    Mem,
    M10s,
    M60s,
    Pss,
    Net,
    Disk,
    Pid,
    Name,
    User,
    Slice,
    Runq,
}

/// Left-to-right order of the sortable columns, so ←/→ walks the header the
/// way glances does rather than jumping around an enum's declaration order.
const SORT_ORDER: [Sort; 14] = [
    Sort::Pid,
    Sort::Slice,
    Sort::User,
    Sort::Name,
    Sort::Cpu,
    Sort::C10s,
    Sort::C60s,
    Sort::Mem,
    Sort::M10s,
    Sort::M60s,
    Sort::Pss,
    Sort::Net,
    Sort::Disk,
    Sort::Runq,
];

impl Sort {
    fn label(self) -> &'static str {
        match self {
            Sort::Cpu => "cpu",
            // Lowercased header names, so the box title names the same column
            // the ▼ marker is sitting on.
            Sort::C10s => "c10s",
            Sort::C60s => "c60s",
            Sort::Mem => "mem",
            Sort::M10s => "m10s",
            Sort::M60s => "m60s",
            Sort::Pss => "pss",
            Sort::Net => "net",
            Sort::Disk => "disk",
            Sort::Pid => "pid",
            Sort::Name => "name",
            Sort::User => "user",
            Sort::Slice => "slice",
            Sort::Runq => "runq",
        }
    }

    /// Step `d` columns along SORT_ORDER, wrapping. Wrapping rather than
    /// clamping because a sort cycle with dead ends at both edges is a worse
    /// answer than one you can spin.
    fn step(self, d: i32) -> Sort {
        let n = SORT_ORDER.len() as i32;
        let i = SORT_ORDER.iter().position(|x| *x == self).unwrap_or(0) as i32;
        SORT_ORDER[(((i + d) % n + n) % n) as usize]
    }
}

/// Which sample of a process to sort and display: the instant value the daemon
/// just measured, or one of the rolling averages it keeps. A 15m average is how
/// you tell a genuine hog from something that merely spiked while you looked.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Win {
    Now,
    M1,
    M5,
    M15,
}

impl Win {
    fn label(self) -> &'static str {
        match self {
            Win::Now => "now",
            Win::M1 => "1m",
            Win::M5 => "5m",
            Win::M15 => "15m",
        }
    }
    fn next(self) -> Win {
        match self {
            Win::Now => Win::M1,
            Win::M1 => Win::M5,
            Win::M5 => Win::M15,
            Win::M15 => Win::Now,
        }
    }
    /// Read `field` from the chosen window, falling back to the instant value
    /// when the daemon has not accumulated that window for this pid yet.
    fn get(self, p: &Value, field: &str) -> f64 {
        match self {
            Win::Now => num(p, field),
            Win::M1 => avg_or(p, "1m", field),
            Win::M5 => avg_or(p, "5m", field),
            Win::M15 => avg_or(p, "15m", field),
        }
    }
}

/// The directory holding a pid's binary. /proc/<pid>/exe is the resolved
/// link, so this survives an argv[0] that was never a path (an ld-linux
/// invocation, a renamed thread, a busybox applet).
/// Cut to `n` CHARACTERS, not bytes — a byte slice through a multibyte name
/// panics, and hostnames are not guaranteed ascii.
fn trunc(s: &str, n: usize) -> String {
    if s.chars().count() <= n { s.to_string() } else { s.chars().take(n).collect() }
}

fn exe_dir(pid: i32) -> Option<String> {
    let exe = fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    Some(exe.parent()?.display().to_string())
}

/// Hand a directory to the desktop's file manager.
///
/// stdio is nulled deliberately: xdg-open's helpers write to stderr, and this
/// process owns an alternate screen — one stray line from a child repaints as
/// corruption the user has to redraw to clear.
fn open_dir(dir: &str) -> Result<(), String> {
    std::process::Command::new("xdg-open")
        .arg(dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// Like num(), but keeps the difference between "zero" and "absent" —
/// mem_pss_bytes is null when the daemon could not read smaps_rollup, and
/// rendering that as 0 would claim a measurement nobody made.
fn num_opt(p: &Value, k: &str) -> Option<f64> {
    p.get(k).and_then(|v| v.as_f64())
}

fn avg_or(p: &Value, win: &str, field: &str) -> f64 {
    p.get("avg")
        .and_then(|a| a.get(win))
        .and_then(|w| w.get(field))
        .and_then(|v| v.as_f64())
        .unwrap_or_else(|| num(p, field))
}

/// Free function, not a method, on purpose: the returned refs borrow the
/// snapshot passed in, so render() can sort against its own local clone and
/// still mutate self.sel/self.offset for scrolling. As a `&self` method the
/// borrow would cover all of Monitor and neither caller would compile.
fn sort_procs<'a>(snap: &'a Value, sort: Sort, desc: bool, win: Win) -> Vec<&'a Value> {
    let mut v: Vec<&Value> = arr(snap, "proc_table").iter().collect();
    v.sort_by(|a, b| {
        let key = |p: &Value| -> f64 {
            match sort {
                Sort::Cpu => win.get(p, "cpu_pct"),
                Sort::Mem => win.get(p, "mem_rss_bytes"),
                Sort::Disk => win.get(p, "read_bytes_per_s") + win.get(p, "write_bytes_per_s"),
                Sort::Net => num(p, "net_rx_bytes_per_s") + num(p, "net_tx_bytes_per_s"),
                Sort::Pss => num(p, "mem_pss_bytes"),
                Sort::Runq => win.get(p, "runq_wait_pct"),
                // Fixed windows, so these ignore `win` entirely. "1m" is the
                // daemon's label for the 60s bucket.
                Sort::C10s => avg_or(p, "10s", "cpu_pct"),
                Sort::C60s => avg_or(p, "1m", "cpu_pct"),
                Sort::M10s => avg_or(p, "10s", "mem_pct"),
                Sort::M60s => avg_or(p, "1m", "mem_pct"),
                Sort::Pid => num(p, "pid"),
                Sort::Name | Sort::User | Sort::Slice => 0.0,
            }
        };
        let ord = match sort {
            // Text columns sort as text; everything else numerically.
            Sort::Name => text(a, "name").to_lowercase().cmp(&text(b, "name").to_lowercase()),
            Sort::User => text(a, "user").to_lowercase().cmp(&text(b, "user").to_lowercase()),
            Sort::Slice => text(a, "slice").cmp(&text(b, "slice")),
            _ => key(a).partial_cmp(&key(b)).unwrap_or(std::cmp::Ordering::Equal),
        };
        if desc { ord.reverse() } else { ord }
    });
    v
}

/// Re-orders an already-sorted list into parent-before-child order, returning
/// each row with its depth.
///
/// The published table is the top-N by CPU, so most parents are simply absent.
/// Anything whose ppid is not in the set is therefore a root — that keeps the
/// forest complete instead of silently dropping the majority of processes,
/// which is what anchoring on pid 1 would do here. Siblings keep the order the
/// sort column already put them in, so `t` re-groups the table without also
/// re-ranking it. Depth is capped so a deep chain cannot eat the name column.
fn tree_order<'a>(procs: &[&'a Value]) -> Vec<(&'a Value, usize)> {
    let present: std::collections::HashSet<i64> =
        procs.iter().map(|p| num(p, "pid") as i64).collect();
    let mut kids: std::collections::HashMap<i64, Vec<usize>> = std::collections::HashMap::new();
    let mut roots: Vec<usize> = vec![];
    for (i, p) in procs.iter().enumerate() {
        let ppid = num(p, "ppid") as i64;
        if ppid != 0 && present.contains(&ppid) && ppid != num(p, "pid") as i64 {
            kids.entry(ppid).or_default().push(i);
        } else {
            roots.push(i);
        }
    }
    let mut out = Vec::with_capacity(procs.len());
    // Explicit stack, not recursion: a pid cycle would blow the real stack,
    // and `seen` makes one terminate instead of hanging the panel.
    let mut seen: std::collections::HashSet<usize> = std::collections::HashSet::new();
    let mut stack: Vec<(usize, usize)> = roots.into_iter().rev().map(|i| (i, 0)).collect();
    while let Some((i, depth)) = stack.pop() {
        if !seen.insert(i) {
            continue;
        }
        out.push((procs[i], depth.min(6)));
        if let Some(cs) = kids.get(&(num(procs[i], "pid") as i64)) {
            for &c in cs.iter().rev() {
                stack.push((c, depth + 1));
            }
        }
    }
    out
}

/// What the `k` menu can send. RESTART is first because it is the thing people
/// actually want most of the time — a wedged process put back rather than a
/// hole where it used to be — and because listing it beside the signals is the
/// only way anyone discovers the daemon grew the verb.
///
/// It is not a signal: the daemon restarts a user systemd unit through
/// systemctl when the pid belongs to one, and otherwise re-execs its argv. The
/// blurb says which, because "restart" quietly meaning two different things is
/// worse than saying so.
const ACTIONS: [(&str, &str); 8] = [
    ("RESTART", "stop it and bring it back (unit, else re-exec argv)"),
    ("TERM", "polite stop, the default"),
    ("INT", "as if you pressed ctrl-c"),
    ("HUP", "reload, or stop if unhandled"),
    ("QUIT", "stop and dump core"),
    ("STOP", "freeze, unignorable"),
    ("CONT", "resume one you froze"),
    ("KILL", "unignorable, no cleanup"),
];

/// Which modal owns the keyboard. btop's Esc opens a menu rather than quitting,
/// and every modal here closes back to None — so Esc is never a way out of the
/// program, which is the whole point of ^c/^d being the only exit.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Overlay {
    None,
    Menu,
    Help,
    Kill,
    Detail,
    /// Pick which machine the whole dashboard is measuring.
    Target,
}

/// The btop-style Esc menu.
const MENU: [(&str, &str); 4] = [
    ("measure", "this machine, or any mesh peer over ssh"),
    ("options", "sorting, averaging window, which boxes are shown"),
    ("help", "every key this dashboard binds"),
    ("quit", "leave the dashboard"),
];

/// Boxes that can be folded away. The two new sections plus net are the ones
/// worth trading for process rows on a short terminal; cpu/mem/proc are the
/// dashboard and stay.
const BOX_NAMES: [&str; 5] = ["storage", "net", "psi", "slices", "mesh"];
const B_STORAGE: usize = 0;
const B_NET: usize = 1;
const B_PSI: usize = 2;
const B_SLICES: usize = 3;
const B_MESH: usize = 4;

// ───────────────────────────────── dashboard ──────────────────────────────────

pub struct Monitor {
    snap: Value,
    guard: Value,
    stale: bool,
    age: f64,
    last_ts: f64,
    host: String,
    kernel: String,

    cpu_hist: Vec<f64>,
    /// One history per core, so each core row can carry its own btop
    /// sparkline instead of a bar that only knows this instant.
    core_hist: Vec<Vec<f64>>,
    mem_hist: Vec<f64>,
    rx_hist: Vec<f64>,
    tx_hist: Vec<f64>,
    psi_hist: Vec<f64>,

    sort: Sort,
    desc: bool,
    win: Win,
    /// `t`: order by the parent/child tree instead of by the sort column.
    tree: bool,
    /// `v`: append the declared service units that are stopped or idle.
    units: bool,
    sel: usize,
    /// The cursor's real identity. `sel` is only where that pid happened to
    /// land in the current ordering, and the ordering changes every tick.
    sel_pid: Option<i64>,
    offset: usize,
    killing: Option<(i32, String)>,
    msg: Option<(String, bool)>,

    overlay: Overlay,
    menu_sel: usize,
    act_sel: usize,
    show: [bool; BOX_NAMES.len()],
    /// The mesh peer table and the remote-snapshot fetcher, both on their
    /// own threads so a dead peer's connect timeout cannot stall a render.
    mesh: crate::dashboards::mesh::Mesh,
    target_sel: usize,
    quit: bool,
    /// Scroll position inside the process detail modal — a full disclosure is
    /// longer than any terminal, so it has to scroll or it is not full.
    detail_scroll: u16,
}

impl Monitor {
    pub fn new() -> Self {
        Monitor {
            snap: Value::Null,
            guard: Value::Null,
            stale: true,
            age: 0.0,
            last_ts: -1.0,
            host: fs::read_to_string("/proc/sys/kernel/hostname").unwrap_or_default().trim().to_string(),
            kernel: fs::read_to_string("/proc/sys/kernel/osrelease").unwrap_or_default().trim().to_string(),
            cpu_hist: vec![],
            core_hist: vec![],
            mem_hist: vec![],
            rx_hist: vec![],
            tx_hist: vec![],
            psi_hist: vec![],
            sort: Sort::Cpu,
            desc: true,
            win: Win::Now,
            tree: false,
            units: false,
            sel: 0,
            sel_pid: None,
            offset: 0,
            killing: None,
            msg: None,
            overlay: Overlay::None,
            menu_sel: 0,
            act_sel: 0,
            show: [true; BOX_NAMES.len()],
            mesh: crate::dashboards::mesh::Mesh::start(),
            target_sel: 0,
            quit: false,
            detail_scroll: 0,
        }
    }

    /// Ask the daemon to signal a pid. We do NOT signal it ourselves: the
    /// daemon owns the protected-slice check, and routing every request
    /// through it keeps one enforcement point rather than two that can drift.
    fn request_kill(&mut self, pid: i32, sig: &str) {
        let path = kill_path();
        let res = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .and_then(|mut f| writeln!(f, "{pid} {sig}"));
        self.msg = Some(match res {
            Ok(()) => (
                if sig == "RESTART" {
                    format!("restart → pid {pid} queued for the daemon")
                } else {
                    format!("SIG{sig} → pid {pid} queued for the daemon")
                },
                false,
            ),
            Err(e) => (format!("could not write {path}: {e}"), true),
        });
    }

    /// The storage box.
    ///
    /// df is not enough here and that is the whole reason this exists: on a
    /// single btrfs pool every subvolume mount reports the SAME total/used, so
    /// fifteen mounts render fifteen identical bars. What actually answers
    /// "what is eating the disk" is per-subvolume quota accounting, which the
    /// daemon reads out of btrfs' own sysfs.
    ///
    ///   referenced — everything the subvolume can see (its apparent size)
    ///   exclusive  — what deleting it would ACTUALLY return; the gap is data
    ///                shared with snapshots and reflinks
    ///
    /// Falls back to the plain statvfs rows when there is no btrfs pool or
    /// quotas are off, which is a normal state, not an error.
    fn storage_lines(&self, s: &Value, width: u16, height: u16) -> Vec<Line<'static>> {
        let mut l: Vec<Line> = vec![];
        let pools = arr(s, "storage");
        let bw = (width as usize).saturating_sub(34).clamp(6, 30);

        for pool in pools {
            let alloc = num(pool, "alloc");
            let size = num(pool, "dev_size").max(1.0);
            let used = num(pool, "alloc_used");
            let label = text(pool, "label");
            let mut sp = vec![Span::styled(
                format!("{:<9}", if label.is_empty() { "btrfs".into() } else { label }),
                Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
            )];
            sp.extend(meter(bw, used / size, "").spans);
            sp.push(Span::styled(
                format!(" {} / {}", fmt_bytes_short(used), fmt_bytes_short(size)),
                Style::default().fg(Color::Gray),
            ));
            l.push(Line::from(sp));
            // Allocated-but-unused chunks are the classic btrfs surprise: the
            // pool can report free space that no allocation can reach until a
            // balance runs, so the two figures are shown apart.
            l.push(Line::from(vec![
                Span::styled("  data ", Style::default().fg(LABEL)),
                Span::styled(
                    format!("{}/{}", fmt_bytes_short(num(pool, "data_used")), fmt_bytes_short(num(pool, "data_total"))),
                    Style::default().fg(Color::Gray),
                ),
                Span::styled("  meta ", Style::default().fg(LABEL)),
                Span::styled(
                    format!("{}/{}", fmt_bytes_short(num(pool, "meta_used")), fmt_bytes_short(num(pool, "meta_total"))),
                    Style::default().fg(Color::Gray),
                ),
                Span::styled("  unalloc ", Style::default().fg(LABEL)),
                Span::styled(fmt_bytes_short((size - alloc).max(0.0)), Style::default().fg(Color::Rgb(120, 200, 255))),
            ]));

            let vols = arr(pool, "volumes");
            l.push(Line::from(vec![
                Span::styled(format!("{:<22}", "  subvolume"), Style::default().fg(DIM)),
                Span::styled(format!("{:>9}", "refer"), Style::default().fg(DIM)),
                Span::styled(format!("{:>9}", "excl"), Style::default().fg(DIM)),
                Span::styled("  quota", Style::default().fg(DIM)),
            ]));
            // One line per remaining row; the list is already sorted biggest
            // first by the daemon, so a truncated box still shows what matters.
            let room = (height as usize).saturating_sub(l.len()).max(1);
            for v in vols.iter().take(room) {
                let refer = num(v, "referenced");
                let excl = num(v, "exclusive");
                let limit = num(v, "limit");
                let mount = text(v, "mount");
                // Tail, not head: /home/diego/.local/share/claude and
                // /home/diego/.local/share/octocode differ only at the end.
                // char-wise so a non-ASCII mount cannot panic on a byte split.
                let short = if mount.chars().count() > 20 {
                    let tail: String = mount.chars().skip(mount.chars().count() - 19).collect();
                    format!("…{tail}")
                } else {
                    mount
                };
                let quota = if limit > 0.0 {
                    Span::styled(
                        format!("  {:>3.0}% of {}", refer / limit * 100.0, fmt_bytes_short(limit)),
                        Style::default().fg(grad(refer / limit)),
                    )
                } else {
                    Span::styled("     —", Style::default().fg(DIM))
                };
                l.push(Line::from(vec![
                    Span::styled(format!("  {short:<20}"), Style::default().fg(Color::Gray)),
                    Span::styled(format!("{:>9}", fmt_bytes_short(refer)), Style::default().fg(grad(refer / size))),
                    Span::styled(format!("{:>9}", fmt_bytes_short(excl)), Style::default().fg(Color::Rgb(140, 150, 170))),
                    quota,
                ]));
            }
        }

        if pools.is_empty() {
            for dk in arr(s, "disks") {
                let pct = num(dk, "pct");
                let mut sp = vec![Span::styled(format!("{:<9}", text(dk, "mount")), Style::default().fg(LABEL))];
                sp.extend(meter(bw, pct / 100.0, "").spans);
                sp.push(Span::styled(
                    format!(" {}/{}", fmt_gib(num(dk, "used_gib")), fmt_gib(num(dk, "total_gib"))),
                    Style::default().fg(Color::Gray),
                ));
                l.push(Line::from(sp));
            }
        }
        l.push(Line::from(vec![
            Span::styled("  io  read ", Style::default().fg(LABEL)),
            Span::styled(fmt_rate_mb(num(s, "disk_r")), Style::default().fg(Color::Rgb(120, 220, 140))),
            Span::styled("  write ", Style::default().fg(LABEL)),
            Span::styled(fmt_rate_mb(num(s, "disk_w")), Style::default().fg(Color::Rgb(220, 140, 240))),
        ]));
        l
    }

    /// The watchdog's slice manager.
    ///
    /// cgroup slices are the units the watchdog actually reasons about: the
    /// protected ones refuse kill requests, and memory.high/memory.max are the
    /// throttle and kill points that decide what dies when this box runs out.
    /// A slice can also be stalling on its own while machine-wide PSI looks
    /// calm, which is why each row carries its own pressure.
    fn slice_lines(&self, s: &Value, width: u16, height: u16) -> Vec<Line<'static>> {
        let slices = arr(s, "slices");
        let mut l: Vec<Line> = vec![Line::from(vec![
            Span::styled(format!("{:<20}", "slice"), Style::default().fg(DIM)),
            Span::styled(format!("{:>8}", "mem"), Style::default().fg(DIM)),
            Span::styled(format!("{:>8}", "swap"), Style::default().fg(DIM)),
            Span::styled(format!("{:>9}", "high"), Style::default().fg(DIM)),
            Span::styled(format!("{:>9}", "max"), Style::default().fg(DIM)),
            Span::styled(format!("{:>6}", "pids"), Style::default().fg(DIM)),
            Span::styled(format!("{:>7}", "mem·io"), Style::default().fg(DIM)),
        ])];
        if slices.is_empty() {
            l.push(Line::from(Span::styled(
                "  no cgroup data — daemon too old to publish slices",
                Style::default().fg(Color::Rgb(240, 160, 90)),
            )));
            return l;
        }
        let _ = width;
        for sl in slices.iter().take((height as usize).saturating_sub(2)) {
            let name = text(sl, "name");
            let cur = num(sl, "current");
            let max = num(sl, "max");
            let high = num(sl, "high");
            let prot = sl.get("protected").and_then(|v| v.as_bool()).unwrap_or(false);
            // A limit of -1 is the daemon's way of saying the file read "max":
            // no limit at all, which is not the same as a limit of zero.
            let lim = |v: f64| -> Span<'static> {
                if v < 0.0 {
                    Span::styled(format!("{:>9}", "—"), Style::default().fg(DIM))
                } else {
                    Span::styled(format!("{:>9}", fmt_bytes_short(v)), Style::default().fg(Color::Gray))
                }
            };
            // Colour against whichever ceiling exists — max if set, else high.
            let ceil = if max > 0.0 { max } else { high };
            let frac = if ceil > 0.0 { cur / ceil } else { 0.0 };
            let mpsi = num(sl, "mem_psi");
            let iopsi = num(sl, "io_psi");
            l.push(Line::from(vec![
                Span::styled(
                    format!("{}{:<width$}", if prot { "🔒" } else { "  " }, name, width = 18),
                    Style::default().fg(if prot { Color::Rgb(240, 160, 90) } else { Color::Gray }),
                ),
                Span::styled(format!("{:>8}", fmt_bytes_short(cur)), Style::default().fg(grad(frac))),
                Span::styled(format!("{:>8}", fmt_bytes_short(num(sl, "swap"))), Style::default().fg(Color::Rgb(140, 150, 170))),
                lim(high),
                lim(max),
                Span::styled(format!("{:>6.0}", num(sl, "pids")), Style::default().fg(LABEL)),
                Span::styled(format!("{mpsi:>3.0}·{iopsi:<3.0}"), Style::default().fg(grad(mpsi.max(iopsi) / 20.0))),
            ]));
        }
        l
    }

    /// A centred modal frame: clear the cells under it (otherwise the boxes
    /// below bleed through the gaps) and draw a titled border.
    fn modal(f: &mut Frame, area: Rect, w: u16, h: u16, title: &str, accent: Color) -> Rect {
        let w = w.min(area.width.saturating_sub(2));
        let h = h.min(area.height.saturating_sub(2));
        let r = Rect {
            x: area.x + (area.width.saturating_sub(w)) / 2,
            y: area.y + (area.height.saturating_sub(h)) / 2,
            width: w,
            height: h,
        };
        f.render_widget(Clear, r);
        let b = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(accent))
            .style(Style::default().bg(Color::Rgb(16, 18, 24)))
            .title(Line::from(vec![
                Span::styled("┤", Style::default().fg(accent)),
                Span::styled(title.to_string(), Style::default().fg(accent).add_modifier(Modifier::BOLD)),
                Span::styled("├", Style::default().fg(accent)),
            ]));
        let inner = b.inner(r);
        f.render_widget(b, r);
        inner
    }

    fn render_kill(&self, f: &mut Frame, area: Rect) {
        let Some((pid, name)) = self.killing.clone() else { return };
        let red = Color::Rgb(240, 72, 72);
        let inner = Self::modal(f, area, 74, ACTIONS.len() as u16 + 5, "act on process", red);
        let mut lines = vec![
            Line::from(vec![
                Span::styled(name, Style::default().fg(Color::White).add_modifier(Modifier::BOLD)),
                Span::styled(format!("  pid {pid}"), Style::default().fg(LABEL)),
            ]),
            Line::from(Span::styled("", Style::default())),
        ];
        for (i, (sig, why)) in ACTIONS.iter().enumerate() {
            let on = i == self.act_sel;
            let mark = if on { "▶" } else { " " };
            let key = Style::default().fg(Color::Black).bg(if *sig == "RESTART" {
                Color::Rgb(120, 220, 140)
            } else {
                Color::Rgb(120, 200, 255)
            });
            lines.push(Line::from(vec![
                Span::styled(format!("{mark} "), Style::default().fg(red)),
                Span::styled(format!(" {} ", i + 1), key),
                Span::styled(
                    format!(" {sig:<8}"),
                    Style::default()
                        .fg(if on { Color::White } else { Color::Gray })
                        .add_modifier(if on { Modifier::BOLD } else { Modifier::empty() }),
                ),
                Span::styled(*why, Style::default().fg(LABEL)),
            ]));
        }
        lines.push(Line::from(Span::styled(
            "↑↓ pick · enter or a digit to send · any other key cancels",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(lines), inner);
    }

    fn render_menu(&self, f: &mut Frame, area: Rect) {
        let accent = Color::Rgb(120, 200, 255);
        let inner = Self::modal(f, area, 68, MENU.len() as u16 + 4, "menu", accent);
        let mut lines = vec![Line::from(Span::styled("", Style::default()))];
        for (i, (item, why)) in MENU.iter().enumerate() {
            let on = i == self.menu_sel;
            lines.push(Line::from(vec![
                Span::styled(if on { " ▶ " } else { "   " }, Style::default().fg(accent)),
                Span::styled(
                    format!("{item:<9}"),
                    Style::default()
                        .fg(if on { Color::White } else { Color::Gray })
                        .add_modifier(if on { Modifier::BOLD } else { Modifier::empty() }),
                ),
                Span::styled(*why, Style::default().fg(LABEL)),
            ]));
        }
        lines.push(Line::from(Span::styled(
            "  ↑↓ enter · esc closes · ^c quits from anywhere",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(lines), inner);
    }

    /// Pick the machine this dashboard measures: this one, or a mesh peer
    /// read over ssh. Peers that did not answer their last probe are still
    /// listed and still selectable — "unreachable" is a probe result, not a
    /// permission, and the ssh attempt gives a better error than we can.
    fn render_target(&self, f: &mut Frame, area: Rect) {
        let accent = Color::Rgb(120, 200, 255);
        let peers = self.mesh.list();
        let cur = self.mesh.target();
        let inner = Self::modal(f, area, 72, peers.len() as u16 + 6, "measure which machine", accent);
        let mut l: Vec<Line> = vec![];
        let mut row = |i: usize, mark: bool, name: String, note: String, style: Style| {
            let sel = i == self.target_sel;
            l.push(Line::from(vec![
                Span::styled(
                    if sel { "▶ " } else { "  " },
                    Style::default().fg(accent),
                ),
                Span::styled(if mark { "● " } else { "  " }, Style::default().fg(Color::Rgb(120, 220, 140))),
                Span::styled(format!("{name:<22}"), if sel { style.add_modifier(Modifier::BOLD) } else { style }),
                Span::styled(note, Style::default().fg(DIM)),
            ]));
        };
        row(
            0,
            cur.is_none(),
            format!("{} (local)", self.host),
            "read straight from the runtime dir".into(),
            Style::default().fg(Color::Gray),
        );
        for (i, p) in peers.iter().enumerate() {
            let note = if !p.probed {
                "probing…".to_string()
            } else if p.up {
                format!("{:.0} ms", p.rtt_ms)
            } else {
                "unreachable".to_string()
            };
            row(
                i + 1,
                cur.as_deref() == Some(p.alias.as_str()),
                format!("{}  {}", p.alias, p.ip),
                note,
                Style::default().fg(if p.probed && !p.up { Color::Rgb(150, 110, 110) } else { Color::Gray }),
            );
        }
        if peers.is_empty() {
            l.push(Line::from(Span::styled(
                "  no mesh peers in ~/.ssh/config",
                Style::default().fg(Color::Rgb(240, 160, 90)),
            )));
        }
        l.push(Line::from(Span::styled(
            "  ↑↓ pick · enter measures it · esc cancels · needs my-konsole-tray on the peer",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(l), inner);
    }

    /// Every binding, in one place. Generated from the same ACTIONS/BOX_NAMES
    /// the handlers use, so a key that changes cannot leave the help behind.
    fn render_help(&self, f: &mut Frame, area: Rect) {
        let accent = Color::Rgb(120, 200, 255);
        let key = |k: &str, d: &str| -> Line<'static> {
            Line::from(vec![
                // 14, not 12: "ctrl-c ctrl-d" is 13 wide and ran straight into
                // its description with no gap at all.
                Span::styled(format!("  {k:<14}"), Style::default().fg(Color::Rgb(120, 220, 140))),
                Span::styled(d.to_string(), Style::default().fg(Color::Gray)),
            ])
        };
        let head = |t: &str| -> Line<'static> {
            Line::from(Span::styled(
                t.to_string(),
                Style::default().fg(accent).add_modifier(Modifier::BOLD),
            ))
        };
        let mut l = vec![
            head("moving"),
            key("↑ ↓", "move the cursor through the process list"),
            key("pgup pgdn", "ten rows at a time"),
            key("home end", "first / last process"),
            head("sorting"),
            key("← →", "move the sort to the next column, glances style"),
            key("c m d g", "sort by cpu · mem · disk · run-queue wait"),
            key("", "PSS is the share-adjusted memory figure; RSS double-counts"),
            key("p n u e s", "sort by pid · name · user · net · slice"),
            key("", "← → also reach C10s C60s M10s M60s"),
            key("i", "invert the direction"),
            key("t", "group by process tree — parents, children, zombies"),
            key("v", "also list declared units that are stopped or idle"),
            // Short enough to survive the 78-column modal: the long version
            // was clipped mid-cycle at "→ 5m".
            key("w", "cycle the CPU%/MEM% window: now → 1m → 5m → 15m"),
            head("acting"),
            key("enter", "full disclosure — command, tree, cpu, mem, io, cgroup"),
            key("k", "act on it — restart, or any of the signals"),
            key("o", "in the detail view: open the binary's folder"),
            head("layout"),
        ];
        for (i, b) in BOX_NAMES.iter().enumerate() {
            l.push(key(
                &format!("{}", i + 1),
                &format!("show/hide the {b} box ({})", if self.show[i] { "shown" } else { "hidden" }),
            ));
        }
        l.push(head("leaving"));
        l.push(key("esc", "open the menu — it does NOT quit"));
        l.push(key("h ? F1", "this page"));
        l.push(key("ctrl-c ctrl-d", "quit. the only keys that do"));
        l.push(Line::from(Span::styled(
            "  any key returns",
            Style::default().fg(DIM),
        )));
        let h = l.len() as u16 + 2;
        let inner = Self::modal(f, area, 78, h, "keys", accent);
        f.render_widget(Paragraph::new(l), inner);
    }

    /// Full disclosure for one process.
    ///
    /// This reads /proc directly rather than the snapshot, which is the one
    /// place in this dashboard that samples anything. That is deliberate and
    /// bounded: it is a single pid, only while its window is open, and the
    /// fields here (cwd, exe, fd count, per-thread state, VmSwap) are ones the
    /// daemon has no reason to publish for all ~500 processes every 2s.
    ///
    /// /proc/PID/environ is NOT read. It routinely holds tokens and passwords,
    /// and "full disclosure" of a process does not extend to putting its
    /// secrets on a screen someone may be sharing.
    fn render_detail(&self, f: &mut Frame, area: Rect) {
        let Some((pid, name, prot, why)) = self.picked() else { return };
        let accent = Color::Rgb(120, 200, 255);
        let inner = Self::modal(
            f,
            area,
            area.width.saturating_sub(8).min(112),
            area.height.saturating_sub(4),
            &format!("{name} · pid {pid}"),
            accent,
        );

        let rd = |f: &str| fs::read_to_string(format!("/proc/{pid}/{f}")).unwrap_or_default();
        let link = |f: &str| {
            fs::read_link(format!("/proc/{pid}/{f}"))
                .map(|p| p.display().to_string())
                .unwrap_or_else(|e| format!("({e})"))
        };
        let status = rd("status");
        let st = |k: &str| -> String {
            status
                .lines()
                .find(|l| l.starts_with(&format!("{k}:")))
                .map(|l| l[k.len() + 1..].trim().to_string())
                .unwrap_or_default()
        };
        let head = |t: &str| -> Line<'static> {
            Line::from(Span::styled(t.to_string(), Style::default().fg(accent).add_modifier(Modifier::BOLD)))
        };
        let kv = |k: &str, v: String| -> Line<'static> {
            Line::from(vec![
                // 21, not 16: "mem% 10s / 1m / 15m" is 19 wide and its value
                // started in the very next cell with no gap at all.
                Span::styled(format!("  {k:<21}"), Style::default().fg(LABEL)),
                Span::styled(v, Style::default().fg(Color::Gray)),
            ])
        };
        // A deep cgroup path runs ~100 chars and used to vanish at the box
        // edge. This modal is the full-disclosure view, so a value that does
        // not fit wraps onto continuation lines rather than being cut.
        let kvw = |k: &str, v: String| -> Vec<Line<'static>> {
            let room = (inner.width as usize).saturating_sub(24).max(16);
            let ch: Vec<char> = v.chars().collect();
            if ch.is_empty() {
                return vec![kv(k, v)];
            }
            ch.chunks(room)
                .enumerate()
                .map(|(i, c)| kv(if i == 0 { k } else { "" }, c.iter().collect()))
                .collect()
        };

        // The row the table is showing, so the modal and the list agree.
        let p = sort_procs(&self.snap, self.sort, self.desc, self.win)
            .get(self.sel)
            .cloned()
            .cloned()
            .unwrap_or(Value::Null);

        let cmdline = fs::read(format!("/proc/{pid}/cmdline"))
            .map(|r| {
                r.split(|b| *b == 0)
                    .filter(|a| !a.is_empty())
                    .map(|a| String::from_utf8_lossy(a).into_owned())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();

        let mut l = vec![head("identity")];
        l.push(kv("name", name.clone()));
        l.push(kv("pid / ppid", format!("{pid} / {}", st("PPid"))));
        l.push(kv("state", st("State")));
        // Uid/Gid are four tab-separated ids (real/effective/saved/fs). Tabs
        // wreck a TUI row, and the real uid is the one people mean.
        let id1 = |k: &str| st(k).split_whitespace().next().unwrap_or("").to_string();
        l.push(kv("user", format!("{}  uid {}  gid {}", text(&p, "user"), id1("Uid"), id1("Gid"))));
        l.push(kv("threads", st("Threads")));
        l.extend(kvw("exe", link("exe")));
        l.extend(kvw("cwd", link("cwd")));
        l.push(kv("fds", fs::read_dir(format!("/proc/{pid}/fd")).map(|d| d.count().to_string()).unwrap_or_else(|e| format!("({e})"))));
        // The command as you would type it. The argv breakdown below answers
        // "how was it split"; this answers "what is it", which is the question
        // people actually arrive with, so it comes first.
        l.extend(kvw("command", if cmdline.is_empty() {
            format!("[{name}]  (kernel thread — no cmdline)")
        } else {
            cmdline.join(" ")
        }));
        l.extend(kvw("comm", st("Name")));
        l.push(kv("argv", format!("{} args", cmdline.len())));
        for (i, a) in cmdline.iter().enumerate().take(12) {
            l.push(Line::from(vec![
                Span::styled(format!("    [{i}] "), Style::default().fg(DIM)),
                Span::styled(a.clone(), Style::default().fg(Color::Rgb(200, 205, 215))),
            ]));
        }
        if cmdline.len() > 12 {
            l.push(Line::from(Span::styled(
                format!("    … {} more", cmdline.len() - 12),
                Style::default().fg(DIM),
            )));
        }

        // ── tree ───────────────────────────────────────────────────────
        // Read straight from /proc, not from proc_table: the table is the
        // top-N by CPU, so a process's real parent is usually not in it and a
        // tree built from the table alone would quietly lie about ancestry.
        let pname = |q: i64| -> String {
            fs::read_to_string(format!("/proc/{q}/status"))
                .ok()
                .and_then(|s| s.lines().find(|l| l.starts_with("Name:")).map(|l| l[5..].trim().to_string()))
                .unwrap_or_else(|| "?".into())
        };
        let pparent = |q: i64| -> Option<i64> {
            fs::read_to_string(format!("/proc/{q}/status"))
                .ok()
                .and_then(|s| s.lines().find(|l| l.starts_with("PPid:")).and_then(|l| l[5..].trim().parse().ok()))
                .filter(|&x: &i64| x > 0)
        };
        l.push(head("tree"));
        // Walk up to init, then print top-down so the chain reads the way a
        // path does. Bounded at 12 because a pid cycle would otherwise hang
        // the panel, and no real ancestry is that deep.
        let mut chain: Vec<i64> = vec![];
        let mut cur = pparent(pid as i64);
        while let Some(q) = cur {
            if chain.contains(&q) || chain.len() >= 12 {
                break;
            }
            chain.push(q);
            cur = pparent(q);
        }
        chain.reverse();
        for (d, q) in chain.iter().enumerate() {
            l.push(Line::from(vec![
                Span::styled(format!("  {}{}", "  ".repeat(d), if d == 0 { "" } else { "└ " }), Style::default().fg(DIM)),
                Span::styled(format!("{} ", pname(*q)), Style::default().fg(Color::Gray)),
                Span::styled(format!("({q})"), Style::default().fg(DIM)),
            ]));
        }
        l.push(Line::from(vec![
            Span::styled(format!("  {}{}", "  ".repeat(chain.len()), if chain.is_empty() { "" } else { "└ " }), Style::default().fg(DIM)),
            Span::styled(format!("{name} "), Style::default().fg(accent).add_modifier(Modifier::BOLD)),
            Span::styled(format!("({pid})  ← this process"), Style::default().fg(DIM)),
        ]));
        // task/<pid>/children is the kernel's own answer, so this costs two
        // reads rather than a scan of every entry in /proc.
        let kids: Vec<i64> = fs::read_to_string(format!("/proc/{pid}/task/{pid}/children"))
            .unwrap_or_default()
            .split_whitespace()
            .filter_map(|x| x.parse().ok())
            .collect();
        if kids.is_empty() {
            l.push(Line::from(Span::styled("      (no children)", Style::default().fg(DIM))));
        }
        for q in kids.iter().take(24) {
            let zst = fs::read_to_string(format!("/proc/{q}/status"))
                .ok()
                .and_then(|s| s.lines().find(|l| l.starts_with("State:")).map(|l| l[6..].trim().to_string()))
                .unwrap_or_default();
            let zombie = zst.starts_with('Z');
            l.push(Line::from(vec![
                Span::styled(format!("  {}└ ", "  ".repeat(chain.len() + 1)), Style::default().fg(DIM)),
                Span::styled(
                    format!("{} ", pname(*q)),
                    Style::default().fg(if zombie { Color::Rgb(240, 72, 72) } else { Color::Gray }),
                ),
                Span::styled(
                    format!("({q}){}", if zombie { "  ZOMBIE" } else { "" }),
                    Style::default().fg(if zombie { Color::Rgb(240, 72, 72) } else { DIM }),
                ),
            ]));
        }
        if kids.len() > 24 {
            l.push(Line::from(Span::styled(
                format!("      … {} more children", kids.len() - 24),
                Style::default().fg(DIM),
            )));
        }
        l.push(kv("children / threads", format!("{} / {}", kids.len(), st("Threads"))));

        l.push(head("cpu"));
        l.push(kv(
            "now / 10s / 1m",
            format!(
                "{:.1}%  {:.1}%  {:.1}%",
                num(&p, "cpu_pct"),
                avg_or(&p, "10s", "cpu_pct"),
                avg_or(&p, "1m", "cpu_pct")
            ),
        ));
        l.push(kv(
            "5m / 15m",
            format!("{:.1}%  {:.1}%", avg_or(&p, "5m", "cpu_pct"), avg_or(&p, "15m", "cpu_pct")),
        ));
        // nice/priority/times live in /proc/PID/stat, not status. comm sits in
        // parentheses there and can itself contain ')', so split after the LAST
        // one — the field-index bug every naive stat parser has.
        let stat = rd("stat");
        let sf: Vec<&str> = stat.rsplit_once(')').map(|(_, r)| r.split_whitespace().collect()).unwrap_or_default();
        // Offsets are proc(5) field numbers minus 3, since sf[0] is field 3.
        let sfi = |i: usize| -> f64 { sf.get(i).and_then(|x| x.parse::<f64>().ok()).unwrap_or(0.0) };
        let hz = 100.0; // USER_HZ is 100 on every Linux target this ships to
        l.push(kv("nice / priority", format!("{} / {}", sfi(16), sfi(15))));
        l.push(kv(
            "cpu time u/s",
            format!("{:.1}s / {:.1}s", sfi(11) / hz, sfi(12) / hz),
        ));
        l.push(kv("faults min/maj", format!("{:.0} / {:.0}", sfi(7), sfi(9))));
        l.push(kv(
            "elapsed",
            fmt_uptime(
                (fs::read_to_string("/proc/uptime")
                    .ok()
                    .and_then(|u| u.split_whitespace().next().and_then(|x| x.parse::<f64>().ok()))
                    .unwrap_or(0.0)
                    - sfi(19) / hz)
                    .max(0.0),
            ),
        ));
        // Time spent runnable but not running: the number that says "this box
        // is oversubscribed" as opposed to "this process is busy".
        l.push(kv("run-queue wait", format!("{:.2}%", num(&p, "runq_wait_pct"))));

        l.push(head("memory"));
        l.push(kv(
            "rss now / 10s / 1m",
            format!(
                "{}  {}  {}",
                fmt_bytes_short(num(&p, "mem_rss_bytes")),
                fmt_bytes_short(avg_or(&p, "10s", "mem_rss_bytes")),
                fmt_bytes_short(avg_or(&p, "1m", "mem_rss_bytes"))
            ),
        ));
        l.push(kv(
            "pss (share-adjusted)",
            match num_opt(&p, "mem_pss_bytes") {
                Some(v) => fmt_bytes_short(v),
                None => "— (not readable for this uid)".into(),
            },
        ));
        l.push(kv(
            "mem% 10s / 1m / 15m",
            format!(
                "{:.2}%  {:.2}%  {:.2}%",
                avg_or(&p, "10s", "mem_pct"),
                avg_or(&p, "1m", "mem_pct"),
                avg_or(&p, "15m", "mem_pct")
            ),
        ));
        // status reports these as "7268852 kB"; every other size in this modal
        // is human-formatted, so parse the number off and match.
        let stb = |k: &str| -> String {
            match st(k).split_whitespace().next().and_then(|n| n.parse::<f64>().ok()) {
                Some(kb) => fmt_bytes_short(kb * 1024.0),
                None => st(k),
            }
        };
        l.push(kv("vm size / peak", format!("{} / {}", stb("VmSize"), stb("VmPeak"))));
        l.push(kv("rss anon / file", format!("{} / {}", stb("RssAnon"), stb("RssFile"))));
        l.push(kv("rss shmem", stb("RssShmem")));
        l.push(kv("swapped out", stb("VmSwap")));

        l.push(head("io"));
        l.push(kv(
            "read / write",
            format!("{}  {}", fmt_bps(num(&p, "read_bytes_per_s")), fmt_bps(num(&p, "write_bytes_per_s"))),
        ));
        for k in ["read_bytes", "write_bytes", "syscr", "syscw"] {
            let v = rd("io")
                .lines()
                .find(|l| l.starts_with(&format!("{k}:")))
                .and_then(|l| l.split_whitespace().nth(1).map(|x| x.to_string()))
                .unwrap_or_else(|| "—".into());
            let pretty = v.parse::<f64>().map(fmt_bytes_short).unwrap_or(v);
            l.push(kv(k, pretty));
        }

        l.push(head("containment"));
        let cg = rd("cgroup");
        l.extend(kvw(
            "cgroup",
            cg.lines().next().and_then(|x| x.rsplit(':').next().map(|s| s.to_string())).unwrap_or_default(),
        ));
        l.push(Line::from(vec![
            Span::styled(format!("  {:<21}", "protected"), Style::default().fg(LABEL)),
            Span::styled(
                if prot { format!("yes — {}", if why.is_empty() { "protected slice".into() } else { why }) } else { "no".into() },
                Style::default().fg(if prot { Color::Rgb(240, 160, 90) } else { Color::Gray }),
            ),
        ]));
        l.push(head("actions"));
        l.push(Line::from(vec![
            Span::styled("  k    ", Style::default().fg(Color::Rgb(120, 220, 140))),
            Span::styled(
                if prot { "blocked — this process is in a protected slice".to_string() }
                else { format!("act on {name}: RESTART, or any signal") },
                Style::default().fg(if prot { Color::Rgb(240, 160, 90) } else { Color::Gray }),
            ),
        ]));
        l.push(Line::from(vec![
            Span::styled("  o    ", Style::default().fg(Color::Rgb(120, 220, 140))),
            Span::styled(
                format!("open the folder holding the binary — {}", exe_dir(pid).unwrap_or_else(|| "unknown".into())),
                Style::default().fg(Color::Gray),
            ),
        ]));
        l.push(Line::from(Span::styled(
            "  ↑↓ pgup pgdn scroll · any other key returns · environ is deliberately not shown",
            Style::default().fg(DIM),
        )));

        let max = (l.len() as u16).saturating_sub(inner.height);
        f.render_widget(
            Paragraph::new(l).scroll((self.detail_scroll.min(max), 0)),
            inner,
        );
    }

    /// The `k` action menu. Arrows or a digit pick; anything else backs out.
    fn kill_key(&mut self, k: KeyCode) {
        let Some((pid, name)) = self.killing.clone() else {
            self.overlay = Overlay::None;
            return;
        };
        let fire = |me: &mut Self, i: usize| {
            me.request_kill(pid, ACTIONS[i].0);
            me.killing = None;
            me.overlay = Overlay::None;
        };
        match k {
            KeyCode::Char(c) if c.is_ascii_digit() => {
                let i = c.to_digit(10).unwrap_or(0) as usize;
                if i >= 1 && i <= ACTIONS.len() {
                    fire(self, i - 1);
                }
            }
            KeyCode::Down => self.act_sel = (self.act_sel + 1) % ACTIONS.len(),
            KeyCode::Up => self.act_sel = (self.act_sel + ACTIONS.len() - 1) % ACTIONS.len(),
            KeyCode::Enter => {
                // Read the index out first: `fire(self, self.act_sel)` would
                // borrow self mutably and then read through it in the same
                // call, which the borrow checker refuses.
                let i = self.act_sel;
                fire(self, i);
            }
            _ => {
                self.msg = Some((format!("cancelled — {name} ({pid}) untouched"), false));
                self.killing = None;
                self.overlay = Overlay::None;
            }
        }
    }

    /// btop's Esc menu: options / help / quit. "options" opens the same page as
    /// `h` — there is one list of what the keys do, and a second screen that
    /// paraphrased it would only go stale.
    fn menu_key(&mut self, k: KeyCode) {
        match k {
            KeyCode::Down => self.menu_sel = (self.menu_sel + 1) % MENU.len(),
            KeyCode::Up => self.menu_sel = (self.menu_sel + MENU.len() - 1) % MENU.len(),
            KeyCode::Enter | KeyCode::Char(' ') => match self.menu_sel {
                0 => {
                    self.target_sel = 0;
                    self.overlay = Overlay::Target;
                }
                1 | 2 => self.overlay = Overlay::Help,
                _ => {
                    // The frame owns quitting, and it only quits on keys it
                    // sees. Stop claiming, then hand it the key it acts on.
                    self.overlay = Overlay::None;
                    self.quit = true;
                }
            },
            KeyCode::Char(c) if c.is_ascii_digit() => {
                let i = c.to_digit(10).unwrap_or(0) as usize;
                if i >= 1 && i <= MENU.len() {
                    self.menu_sel = i - 1;
                    self.menu_key(KeyCode::Enter);
                }
            }
            _ => self.overlay = Overlay::None,
        }
    }

    /// The row the cursor is on, copied out of the snapshot.
    ///
    /// Copied, not borrowed: sort_procs() borrows self.snap for as long as its
    /// Vec lives, so anything that then wants to touch self.msg / self.overlay
    /// has to take owned values first. Every caller here needs to do exactly
    /// that, so the copy lives in one place instead of four.
    /// The single source of truth for row order. picked(), the key handler
    /// and the renderer all go through it, so the cursor cannot mean one row
    /// in one of them and a different row in another.
    fn rows(&self) -> Vec<&Value> {
        let procs = sort_procs(&self.snap, self.sort, self.desc, self.win);
        if self.tree {
            tree_order(&procs).into_iter().map(|(p, _)| p).collect()
        } else {
            procs
        }
    }

    /// The declared service units worth listing under the live processes.
    ///
    /// Two kinds, and they answer different halves of "what is supposed to be
    /// running": units that are NOT active+running have no process at all, so
    /// a process table can never show them; units that are active+running but
    /// whose name does not appear in the table are up and doing nothing, which
    /// in a CPU-ranked table is indistinguishable from absent.
    ///
    /// The second test is a NAME heuristic — unit "foo.service" against
    /// process "foo" — because the snapshot carries no unit-to-pid mapping.
    /// It can mislabel a busy process as idle when the unit and the binary are
    /// named differently; it never invents a unit that does not exist.
    fn unit_rows(&self, s: &Value) -> Vec<(String, String, String)> {
        if !self.units {
            return vec![];
        }
        let live: std::collections::HashSet<String> =
            arr(s, "proc_table").iter().map(|p| text(p, "name")).collect();
        arr(s, "services")
            .iter()
            .filter_map(|u| {
                let name = text(u, "name");
                let active = text(u, "active");
                let sub = text(u, "sub");
                let running = active == "active" && sub == "running";
                let stem = name.trim_end_matches(".service").to_string();
                if running && live.contains(&stem) {
                    return None;
                }
                let state = if running { "idle".to_string() } else { format!("{active}/{sub}") };
                Some((name, text(u, "scope"), state))
            })
            .collect()
    }

    /// None when the cursor is parked on an appended unit row: those have no
    /// pid, so every action keyed off a pid correctly does nothing.
    fn picked(&self) -> Option<(i32, String, bool, String)> {
        let procs = self.rows();
        procs.get(self.sel).map(|p| {
            (
                num(p, "pid") as i32,
                text(p, "name"),
                p.get("protected").and_then(|v| v.as_bool()).unwrap_or(false),
                text(p, "protected_reason"),
            )
        })
    }
}

impl Dashboard for Monitor {
    fn title(&self) -> String {
        "📊 monitor".into()
    }
    fn tick_ms(&self) -> u64 {
        1000
    }

    fn update(&mut self) {
        // A remote target swaps the SOURCE of the snapshot and nothing else:
        // every box below reads the same shape either way, which is the whole
        // benefit of the daemon publishing a file rather than the panel
        // sampling. The ssh fetch itself happens on the mesh thread.
        let (s, err) = match self.mesh.target() {
            None => (read_json(&snapshot_path()), String::new()),
            Some(_) => self.mesh.remote_snapshot(),
        };
        if !err.is_empty() {
            self.msg = Some((err, true));
        }
        if s.is_null() {
            self.stale = true;
            return;
        }
        let ts = num(&s, "ts");
        self.age = (now_secs() - ts).max(0.0);
        // The daemon publishes every 2s. Older than a few periods means it
        // died, and showing its last numbers forever is how a dead publisher
        // hides — the graphs must visibly stop, not quietly freeze.
        self.stale = self.age > 15.0;
        // Only extend history when the publisher actually moved, otherwise a
        // 1s poll against a 2s publisher draws every sample twice and the
        // graph's time axis silently runs at half speed.
        if ts > self.last_ts {
            self.last_ts = ts;
            push(&mut self.cpu_hist, num(&s, "cpu"));
            let cores = arr(&s, "cores");
            self.core_hist.resize(cores.len(), vec![]);
            for (i, c) in cores.iter().enumerate() {
                push(&mut self.core_hist[i], c.as_f64().unwrap_or(0.0));
            }
            push(&mut self.mem_hist, num(&s, "mem"));
            push(&mut self.rx_hist, num(&s, "net_rx"));
            push(&mut self.tx_hist, num(&s, "net_tx"));
            let worst = num(&s, "psi.cpu.some10")
                .max(num(&s, "psi.io.full10"))
                .max(num(&s, "psi.memory.full10"));
            push(&mut self.psi_hist, worst);
        }
        self.snap = s;
        // Published by the SYSTEM watchdog, a different publisher on a
        // different cadence. Absent until that unit is running, so every read
        // below has to tolerate Null.
        self.guard = read_json("/run/freeze-guard.json");
    }

    /// Everything except ^c/^d, which frame.rs takes unconditionally. Esc is
    /// bound here precisely so it does NOT reach the frame's quit.
    fn wants_quit(&self) -> bool {
        self.quit
    }

    fn claims(&self, k: KeyCode) -> bool {
        // A modal owns the whole keyboard: while one is up, q must close it
        // rather than close the program, and a stray 'c' must not re-sort the
        // list under the pid you are aiming at.
        self.overlay != Overlay::None || k == KeyCode::Esc
    }

    fn on_key(&mut self, k: KeyCode) {
        let snap = self.snap.clone();
        let n = arr(&self.snap, "proc_table").len() + self.unit_rows(&snap).len();
        match self.overlay {
            Overlay::Kill => return self.kill_key(k),
            Overlay::Menu => return self.menu_key(k),
            Overlay::Help => {
                // Any key dismisses a page of text; making people find the one
                // right key to leave a help screen is its own small insult.
                self.overlay = Overlay::None;
                return;
            }
            Overlay::Target => {
                let n = self.mesh.list().len() + 1;
                match k {
                    KeyCode::Down => self.target_sel = (self.target_sel + 1) % n,
                    KeyCode::Up => self.target_sel = (self.target_sel + n - 1) % n,
                    KeyCode::Enter | KeyCode::Char(' ') => {
                        let peers = self.mesh.list();
                        let pick = if self.target_sel == 0 {
                            None
                        } else {
                            peers.get(self.target_sel - 1).map(|p| p.alias.clone())
                        };
                        self.mesh.set_target(pick.clone());
                        // History is per-machine. Carrying the old graphs into
                        // a new target would draw one box's past as another's.
                        self.cpu_hist.clear();
                        self.core_hist.clear();
                        self.mem_hist.clear();
                        self.rx_hist.clear();
                        self.tx_hist.clear();
                        self.psi_hist.clear();
                        self.last_ts = -1.0;
                        self.msg = Some((
                            match &pick {
                                Some(a) => format!("measuring {a} over ssh"),
                                None => "measuring this machine".into(),
                            },
                            false,
                        ));
                        self.overlay = Overlay::None;
                    }
                    _ => self.overlay = Overlay::None,
                }
                return;
            }
            Overlay::Detail => {
                // `k` acts here rather than scrolling. Arriving at the full
                // disclosure and then having to back out to signal the thing
                // you are looking at is the wrong shape, so the actions live
                // where the evidence is. Scrolling keeps the arrows and j.
                match k {
                    KeyCode::Down | KeyCode::Char('j') => self.detail_scroll = self.detail_scroll.saturating_add(1),
                    KeyCode::Up => self.detail_scroll = self.detail_scroll.saturating_sub(1),
                    KeyCode::PageDown => self.detail_scroll = self.detail_scroll.saturating_add(10),
                    KeyCode::PageUp => self.detail_scroll = self.detail_scroll.saturating_sub(10),
                    KeyCode::Home => self.detail_scroll = 0,
                    KeyCode::Char('k') => {
                        if let Some((pid, name, prot, why)) = self.picked() {
                            if prot {
                                let why = if why.is_empty() { "protected slice".to_string() } else { why };
                                self.msg = Some((format!("{name} ({pid}) is protected — {why}"), true));
                                self.overlay = Overlay::None;
                            } else {
                                self.msg = None;
                                self.killing = Some((pid, name));
                                self.act_sel = 0;
                                self.overlay = Overlay::Kill;
                            }
                        }
                    }
                    KeyCode::Char('o') => {
                        if let Some((pid, _, _, _)) = self.picked() {
                            self.msg = Some(match exe_dir(pid) {
                                Some(d) => match open_dir(&d) {
                                    Ok(()) => (format!("opened {d}"), false),
                                    Err(e) => (format!("xdg-open {d}: {e}"), true),
                                },
                                None => (format!("pid {pid} has no readable exe link"), true),
                            });
                            self.overlay = Overlay::None;
                        }
                    }
                    _ => self.overlay = Overlay::None,
                }
                return;
            }
            Overlay::None => {}
        }
        match k {
            KeyCode::Esc => {
                self.overlay = Overlay::Menu;
                self.menu_sel = 0;
            }
            KeyCode::Char('h') | KeyCode::Char('?') | KeyCode::F(1) => self.overlay = Overlay::Help,
            KeyCode::Down => self.sel = (self.sel + 1).min(n.saturating_sub(1)),
            KeyCode::Up => self.sel = self.sel.saturating_sub(1),
            KeyCode::PageDown => self.sel = (self.sel + 10).min(n.saturating_sub(1)),
            KeyCode::PageUp => self.sel = self.sel.saturating_sub(10),
            KeyCode::Home => self.sel = 0,
            KeyCode::End => self.sel = n.saturating_sub(1),
            // glances' arrows: walk the sort column along the header. Landing
            // on the same column twice does not flip the direction — `i` does
            // that — so ←→← puts you back exactly where you started.
            KeyCode::Left => self.sort = self.sort.step(-1),
            KeyCode::Right => self.sort = self.sort.step(1),
            KeyCode::Char('c') => self.sort = Sort::Cpu,
            KeyCode::Char('m') => self.sort = Sort::Mem,
            KeyCode::Char('d') => self.sort = Sort::Disk,
            KeyCode::Char('p') => self.sort = Sort::Pid,
            KeyCode::Char('n') => self.sort = Sort::Name,
            KeyCode::Char('u') => self.sort = Sort::User,
            KeyCode::Char('g') => self.sort = Sort::Runq,
            KeyCode::Char('e') => self.sort = Sort::Net,
            KeyCode::Char('s') => self.sort = Sort::Slice,
            KeyCode::Char('i') => self.desc = !self.desc,
            KeyCode::Char('w') => self.win = self.win.next(),
            KeyCode::Char('v') => {
                self.units = !self.units;
                self.msg = Some((
                    format!(
                        "declared units {}",
                        if self.units { "shown — stopped and idle services" } else { "hidden" }
                    ),
                    false,
                ));
            }
            KeyCode::Char('t') => {
                self.tree = !self.tree;
                self.msg = Some((
                    format!("process tree {}", if self.tree { "on" } else { "off" }),
                    false,
                ));
            }
            // Fold a box away to give the process table its rows back. Same
            // idea as btop's presets, minus the config file.
            KeyCode::Char(c @ '1'..='5') => {
                let i = c as usize - '1' as usize;
                self.show[i] = !self.show[i];
                self.msg = Some((
                    format!("{} {}", BOX_NAMES[i], if self.show[i] { "shown" } else { "hidden" }),
                    false,
                ));
            }
            KeyCode::Enter => {
                if self.picked().is_some() {
                    self.detail_scroll = 0;
                    self.overlay = Overlay::Detail;
                }
            }
            KeyCode::Char('k') => {
                if let Some((pid, name, prot, why)) = self.picked() {
                    // The daemon refuses these anyway; saying so here means the
                    // answer arrives before the keystroke, not after a silent
                    // no-op the user has to go read a log to explain.
                    if prot {
                        let why = if why.is_empty() { "protected slice".to_string() } else { why };
                        self.msg = Some((format!("{name} ({pid}) is protected — {why}"), true));
                    } else {
                        self.msg = None;
                        self.killing = Some((pid, name));
                        self.act_sel = 0;
                        self.overlay = Overlay::Kill;
                    }
                }
            }
            _ => {}
        }
        // Re-anchor on whatever pid the cursor now sits on. Without this the
        // selection is a bare index, and the next tick's re-sort slides a
        // different process underneath it.
        let now_on = self.rows().get(self.sel).map(|p| num(p, "pid") as i64);
        self.sel_pid = now_on;
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        let s = self.snap.clone();

        // The lower band only costs rows when something is in it; folding both
        // its boxes away (2/4) gives every one of those rows to the process
        // table rather than leaving a labelled gap.
        let low_h: u16 =
            if self.show[B_PSI] || self.show[B_SLICES] || self.show[B_MESH] { 10 } else { 0 };
        let rows = Layout::vertical([
            Constraint::Length(1),     // header
            Constraint::Length(11),    // cpu
            Constraint::Length(13),    // mem | storage | net
            Constraint::Length(low_h), // psi | slices
            Constraint::Min(6),        // procs
            Constraint::Length(1),     // status
        ])
        .split(area);

        // ── header ────────────────────────────────────────────────────────────
        let uptime = fs::read_to_string("/proc/uptime")
            .ok()
            .and_then(|s| s.split_whitespace().next().and_then(|x| x.parse::<f64>().ok()))
            .unwrap_or(0.0);
        let mut head = vec![
            Span::styled(format!(" {} ", self.host), Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD)),
            Span::styled(format!("· {} · up {} ", self.kernel, fmt_uptime(uptime)), Style::default().fg(LABEL)),
        ];
        if num(&s, "battery.present") != 0.0 || !text(&s, "battery.status").is_empty() {
            let b = num(&s, "battery.pct");
            let chg = s.get("battery").and_then(|x| x.get("charging")).and_then(|v| v.as_bool()).unwrap_or(false);
            head.push(Span::styled(
                format!("· bat {}{:.0}% ", if chg { "↑" } else { "" }, b),
                Style::default().fg(grad(1.0 - b / 100.0)),
            ));
        }
        head.push(Span::styled(
            if self.stale {
                format!("· ⚠ SNAPSHOT {:.0}s OLD — daemon not publishing ", self.age)
            } else {
                format!("· snapshot {:.0}s ago ", self.age)
            },
            Style::default().fg(if self.stale { Color::Rgb(240, 72, 72) } else { DIM }),
        ));
        f.render_widget(Paragraph::new(Line::from(head)), rows[0]);

        // ── cpu box ───────────────────────────────────────────────────────────
        let cpu_b = bbox("cpu", "");
        let cpu_in = cpu_b.inner(rows[1]);
        f.render_widget(cpu_b, rows[1]);
        let cores = arr(&s, "cores");
        // Two columns of core meters when there are enough cores to warrant it,
        // so the graph keeps the width that makes braille worth using.
        let core_cols = if cores.len() > 8 { 2 } else { 1 };
        let core_w = 24u16 * core_cols as u16;
        let cpu_split = Layout::horizontal([Constraint::Min(20), Constraint::Length(core_w)]).split(cpu_in);
        let cpu_left = Layout::vertical([Constraint::Min(3), Constraint::Length(1), Constraint::Length(2)]).split(cpu_split[0]);

        let gw = cpu_left[0].width as usize;
        let gh = cpu_left[0].height as usize;
        f.render_widget(Paragraph::new(braille_graph(&self.cpu_hist, 100.0, gw, gh)), cpu_left[0]);

        let cpu_pct = num(&s, "cpu");
        let mw = (cpu_left[1].width as usize).saturating_sub(10);
        f.render_widget(
            Paragraph::new(meter(mw, cpu_pct / 100.0, &format!("{cpu_pct:5.1}%"))),
            cpu_left[1],
        );

        let d = |k: &str| num(&s, &format!("cpu_detail.{k}"));
        let detail = Line::from(vec![
            Span::styled("usr ", Style::default().fg(LABEL)),
            Span::styled(format!("{:>5.1}", d("user")), Style::default().fg(grad(d("user") / 100.0))),
            Span::styled("  sys ", Style::default().fg(LABEL)),
            Span::styled(format!("{:>5.1}", d("system")), Style::default().fg(grad(d("system") / 100.0))),
            Span::styled("  io ", Style::default().fg(LABEL)),
            Span::styled(format!("{:>5.1}", d("iowait")), Style::default().fg(grad(d("iowait") / 20.0))),
            Span::styled("  irq ", Style::default().fg(LABEL)),
            Span::styled(format!("{:>4.1}", d("irq")), Style::default().fg(Color::Gray)),
            Span::styled("  nice ", Style::default().fg(LABEL)),
            Span::styled(format!("{:>4.1}", d("nice")), Style::default().fg(Color::Gray)),
            Span::styled("  steal ", Style::default().fg(LABEL)),
            Span::styled(format!("{:>4.1}", d("steal")), Style::default().fg(Color::Gray)),
        ]);
        let ncpu = cores.len().max(1) as f64;
        let load = Line::from(vec![
            Span::styled("load ", Style::default().fg(LABEL)),
            Span::styled(format!("{:.2}", num(&s, "load1")), Style::default().fg(grad(num(&s, "load1") / ncpu))),
            Span::styled(format!(" {:.2} {:.2}", num(&s, "load5"), num(&s, "load15")), Style::default().fg(Color::Gray)),
            Span::styled(format!("   {} cores", cores.len()), Style::default().fg(LABEL)),
        ]);
        f.render_widget(Paragraph::new(vec![detail, load]), cpu_left[2]);

        // per-core meters
        let per = (cores.len() + core_cols - 1) / core_cols.max(1);
        let core_areas = Layout::horizontal(vec![Constraint::Ratio(1, core_cols as u32); core_cols]).split(cpu_split[1]);
        for (ci, ca) in core_areas.iter().enumerate() {
            let lines: Vec<Line> = cores
                .iter()
                .enumerate()
                .skip(ci * per)
                .take(per.min(ca.height as usize))
                .map(|(i, c)| {
                    let v = c.as_f64().unwrap_or(0.0);
                    // btop gives every core its own graph, not just a bar. A
                    // single braille row is 4 levels tall and 2 samples wide
                    // per cell — coarse, but it distinguishes "pinned" from
                    // "just spiked", which a bar cannot.
                    let gw = ((ca.width as usize) / 3).clamp(4, 10);
                    let bw = (ca.width as usize).saturating_sub(gw + 10);
                    let mut sp = vec![Span::styled(format!("{i:>2} "), Style::default().fg(LABEL))];
                    if let Some(h) = self.core_hist.get(i) {
                        sp.extend(braille_graph(h, 100.0, gw, 1).pop().map(|l| l.spans).unwrap_or_default());
                    } else {
                        sp.push(Span::raw(" ".repeat(gw)));
                    }
                    sp.push(Span::raw(" "));
                    sp.extend(meter(bw, v / 100.0, "").spans);
                    sp.push(Span::styled(format!(" {v:>3.0}%"), Style::default().fg(grad(v / 100.0))));
                    Line::from(sp)
                })
                .collect();
            f.render_widget(Paragraph::new(lines), *ca);
        }

        // ── mem | storage | net ───────────────────────────────────────────────
        let mid = Layout::horizontal(if self.show[B_STORAGE] {
            vec![Constraint::Percentage(36), Constraint::Percentage(37), Constraint::Percentage(27)]
        } else {
            vec![Constraint::Percentage(48), Constraint::Percentage(52)]
        })
        .split(rows[2]);

        // memory — RAM and swap kept apart on purpose. They are two different
        // stores, and a page can be in BOTH at once (SwapCached), so a single
        // merged "memory used" figure is arithmetic on overlapping sets.
        let mem_b = bbox("mem", "");
        let mem_in = mem_b.inner(mid[0]);
        f.render_widget(mem_b, mid[0]);
        let bw = (mem_in.width as usize).saturating_sub(24);
        let mut ml: Vec<Line> = vec![];
        let bar = |label: &str, pct: f64, txt: String| -> Line<'static> {
            let mut sp = vec![Span::styled(format!("{label:<7}"), Style::default().fg(LABEL))];
            sp.extend(meter(bw, pct / 100.0, "").spans);
            sp.push(Span::styled(format!(" {txt}"), Style::default().fg(Color::Gray)));
            Line::from(sp)
        };
        let md = |k: &str| num(&s, &format!("mem_detail.{k}"));
        let sd = |k: &str| num(&s, &format!("swap_detail.{k}"));
        let total = md("total").max(0.001);

        ml.push(Line::from(Span::styled(
            "RAM",
            Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
        )));
        ml.push(bar("used", num(&s, "mem"), format!("{} / {}", fmt_gib(md("used")), fmt_gib(total))));
        // The composition line: these four are disjoint and sum to total, which
        // is what makes it a breakdown rather than four unrelated numbers.
        // anon = process memory, cached/buffers = reclaimable page cache,
        // kernel = slab+stacks+page tables, free = untouched.
        let part = |name: &str, v: f64, c: Color| -> Vec<Span<'static>> {
            vec![
                Span::styled(format!(" {name} "), Style::default().fg(LABEL)),
                Span::styled(fmt_gib(v), Style::default().fg(c)),
                Span::styled(format!(" {:>4.1}%", v / total * 100.0), Style::default().fg(DIM)),
            ]
        };
        let mut comp = vec![Span::styled("  ", Style::default())];
        comp.extend(part("anon", md("anon"), Color::Rgb(240, 160, 90)));
        comp.extend(part("cache", md("cached"), Color::Rgb(120, 220, 140)));
        ml.push(Line::from(comp));
        let mut comp2 = vec![Span::styled("  ", Style::default())];
        comp2.extend(part("kern", md("kernel"), Color::Rgb(190, 150, 240)));
        comp2.extend(part("free", md("free"), Color::Rgb(120, 200, 255)));
        ml.push(Line::from(comp2));
        ml.push(Line::from(vec![
            Span::styled("  buffers ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(md("buffers")), Style::default().fg(Color::Gray)),
            Span::styled(" shmem ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(md("shmem")), Style::default().fg(Color::Gray)),
            // The only figure that answers "can I start something big": it
            // already accounts for what the kernel would reclaim.
            Span::styled(" avail ", Style::default().fg(LABEL)),
            Span::styled(
                fmt_gib(md("available")),
                Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
            ),
        ]));
        ml.push(Line::from(vec![
            Span::styled("  dirty ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(md("dirty")), Style::default().fg(grad(md("dirty") / 2.0))),
            Span::styled(" wb ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(md("writeback")), Style::default().fg(Color::Gray)),
            Span::styled(" commit ", Style::default().fg(LABEL)),
            Span::styled(
                format!("{}/{}", fmt_gib(md("committed")), fmt_gib(md("commit_limit"))),
                Style::default().fg(Color::Gray),
            ),
        ]));

        ml.push(Line::from(Span::styled(
            "SWAP",
            Style::default().fg(Color::Rgb(190, 150, 240)).add_modifier(Modifier::BOLD),
        )));
        ml.push(bar("used", num(&s, "swap"), format!("{} / {}", fmt_gib(sd("used")), fmt_gib(sd("total")))));
        ml.push(Line::from(vec![
            Span::styled("  free ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(sd("free")), Style::default().fg(Color::Gray)),
            // Pages that are on disk AND still resident. Faulting one back is
            // free, which is why swap "used" alone overstates the damage.
            Span::styled(" cached ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(sd("cached")), Style::default().fg(Color::Gray)),
            Span::styled(" zswap ", Style::default().fg(LABEL)),
            Span::styled(
                format!("{}→{}", fmt_gib(sd("zswapped")), fmt_gib(sd("zswap"))),
                Style::default().fg(Color::Gray),
            ),
        ]));
        // The user slice's own cap is what actually decides who gets OOM-killed
        // on this machine — RAM% can look calm while the slice is at its limit.
        ml.push(bar(
            "slice",
            num(&s, "slice_pct"),
            format!("{} / {}", fmt_gib(num(&s, "slice_gib")), fmt_gib(num(&s, "slice_max_gib"))),
        ));
        f.render_widget(Paragraph::new(ml), mem_in);

        // ── storage ───────────────────────────────────────────────────────────
        if self.show[B_STORAGE] {
            let st_b = bbox("storage", "");
            let st_in = st_b.inner(mid[1]);
            f.render_widget(st_b, mid[1]);
            f.render_widget(Paragraph::new(self.storage_lines(&s, st_in.width, st_in.height)), st_in);
        }
        let net_area = mid[if self.show[B_STORAGE] { 2 } else { 1 }];

        // network
        if self.show[B_NET] {
            let net_b = bbox("net", "");
            let net_in = net_b.inner(net_area);
            f.render_widget(net_b, net_area);
            let nrows = Layout::vertical([
                Constraint::Length(1),
                Constraint::Min(2),
                Constraint::Length(1),
                Constraint::Min(2),
            ])
            .split(net_in);
            let rx_max = self.rx_hist.iter().cloned().fold(0.001, f64::max);
            let tx_max = self.tx_hist.iter().cloned().fold(0.001, f64::max);
            f.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("▼ ", Style::default().fg(Color::Rgb(120, 220, 140))),
                    Span::styled(fmt_rate_mb(num(&s, "net_rx")), Style::default().fg(Color::Gray)),
                    Span::styled(format!("  peak {}", fmt_rate_mb(rx_max)), Style::default().fg(DIM)),
                ])),
                nrows[0],
            );
            f.render_widget(
                Paragraph::new(braille_graph(&self.rx_hist, rx_max, nrows[1].width as usize, nrows[1].height as usize)),
                nrows[1],
            );
            f.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("▲ ", Style::default().fg(Color::Rgb(220, 140, 240))),
                    Span::styled(fmt_rate_mb(num(&s, "net_tx")), Style::default().fg(Color::Gray)),
                    Span::styled(format!("  peak {}", fmt_rate_mb(tx_max)), Style::default().fg(DIM)),
                ])),
                nrows[2],
            );
            f.render_widget(
                Paragraph::new(braille_graph(&self.tx_hist, tx_max, nrows[3].width as usize, nrows[3].height as usize)),
                nrows[3],
            );
        }

        // PSI — the box that matters most on this machine. systemd-oomd watches
        // MEMORY pressure only; the 2026-08-22 freeze was IO-bound, invisible to
        // it, and only freeze-guard's voters covered it. So show both: the raw
        // some/full averages, and which of the guard's voters are armed.
        // Three boxes share this band and any of them can be folded away, so
        // the split is built from whichever are actually shown. Fill weights
        // rather than percentages: they stay correct for every subset instead
        // of leaving a gap whenever the numbers no longer add to 100.
        let low_boxes: Vec<usize> =
            [B_PSI, B_SLICES, B_MESH].into_iter().filter(|i| self.show[*i]).collect();
        let low = Layout::horizontal(if low_boxes.is_empty() {
            vec![Constraint::Fill(1)]
        } else {
            low_boxes
                .iter()
                .map(|i| match *i {
                    B_PSI => Constraint::Fill(34),
                    B_SLICES => Constraint::Fill(42),
                    _ => Constraint::Fill(24),
                })
                .collect::<Vec<_>>()
        })
        .split(rows[3]);
        let slot = |b: usize| low_boxes.iter().position(|x| *x == b).unwrap_or(0);
        if self.show[B_PSI] {
            let psi_area = low[slot(B_PSI)];
            let psi_b = bbox("psi", "");
            let psi_in = psi_b.inner(psi_area);
            f.render_widget(psi_b, psi_area);
            let mut pl: Vec<Line> = vec![Line::from(vec![
                Span::styled("        10s    60s   300s  now", Style::default().fg(LABEL)),
            ])];
            for (kind, short) in [("cpu", "cpu"), ("io", "io"), ("memory", "mem")] {
                for band in ["some", "full"] {
                    // `full` means every task was stalled — on io it is the number
                    // that tracked the freeze, so it is never scaled the same as
                    // `some`, which is routinely nonzero on a busy but healthy box.
                    let scale = if band == "full" { 20.0 } else { 60.0 };
                    let v10 = num(&s, &format!("psi.{kind}.{band}10"));
                    let v60 = num(&s, &format!("psi.{kind}.{band}60"));
                    let v300 = num(&s, &format!("psi.{kind}.{band}300"));
                    let mut sp = vec![
                        Span::styled(
                            format!("{:<4}", if band == "some" { short } else { "" }),
                            Style::default().fg(Color::Rgb(120, 200, 255)),
                        ),
                        Span::styled(format!("{:<4}", band), Style::default().fg(LABEL)),
                        Span::styled(format!("{v10:>5.2}"), Style::default().fg(grad(v10 / scale))),
                        Span::styled(format!("{v60:>7.2}"), Style::default().fg(grad(v60 / scale))),
                        Span::styled(format!("{v300:>7.2}"), Style::default().fg(grad(v300 / scale))),
                        Span::raw("  "),
                    ];
                    // A thermometer per row. The numbers alone make you do the
                    // "is 4.2 bad for `full`?" arithmetic every time; the bar
                    // is already scaled by the band, so a long bar means bad
                    // whichever row it is on. Driven by the 10s figure — the
                    // one that moves while you are watching.
                    let tw = (psi_in.width as usize).saturating_sub(27).min(18);
                    if tw >= 4 {
                        sp.extend(meter(tw, v10 / scale, "").spans);
                    }
                    pl.push(Line::from(sp));
                }
        }
        let voters = arr(&self.guard, "voters");
        if voters.is_empty() {
            pl.push(Line::from(Span::styled(
                "guard: no /run/freeze-guard.json",
                Style::default().fg(Color::Rgb(240, 72, 72)),
            )));
        } else {
            let armed: Vec<String> = voters
                .iter()
                .filter(|v| v.get("armed").and_then(|x| x.as_bool()).unwrap_or(false))
                .map(|v| text(v, "id"))
                .collect();
            // Worst voter as a fraction of its own threshold — one number for
            // "how close is the guard to firing", which no raw PSI cell gives.
            let worst = voters
                .iter()
                .map(|v| {
                    let t = num(v, "threshold");
                    if t > 0.0 { num(v, "value") / t } else { 0.0 }
                })
                .fold(0.0, f64::max);
            pl.push(Line::from(vec![
                Span::styled("guard ", Style::default().fg(LABEL)),
                Span::styled(format!("{}/{} voters", armed.len(), voters.len()), Style::default().fg(Color::Gray)),
                Span::styled(format!("  worst {:.0}%", worst * 100.0), Style::default().fg(grad(worst))),
            ]));
            if !armed.is_empty() {
                pl.push(Line::from(Span::styled(
                    format!("ARMED: {}", armed.join(", ")),
                    Style::default().fg(Color::Rgb(240, 72, 72)).add_modifier(Modifier::BOLD),
                )));
            }
        }
        f.render_widget(Paragraph::new(pl), psi_in);
        }

        // ── watchdog slice manager ───────────────────────────────────────────
        if self.show[B_SLICES] {
            let sl_area = low[slot(B_SLICES)];
            let sl_b = bbox("watchdog · slices", "protected slices refuse kills");
            let sl_in = sl_b.inner(sl_area);
            f.render_widget(sl_b, sl_area);
            f.render_widget(Paragraph::new(self.slice_lines(&s, sl_in.width, sl_in.height)), sl_in);
        }

        // ── mesh ─────────────────────────────────────────────────────────────
        // wg(8) cannot be read unprivileged, so "up" here is a TCP connect the
        // kernel completed to the peer's sshd, not a handshake age. That is a
        // narrower claim and a truer one: it means you can reach the machine.
        if self.show[B_MESH] {
            let target = self.mesh.target();
            let mesh_area = low[slot(B_MESH)];
            let mesh_b = bbox("mesh", "esc → measure");
            let mesh_in = mesh_b.inner(mesh_area);
            f.render_widget(mesh_b, mesh_area);
            let peers = self.mesh.list();
            let mut l: Vec<Line> = vec![Line::from(vec![
                Span::styled(format!("{:<16}", "peer"), Style::default().fg(DIM)),
                Span::styled(format!("{:>10}", "addr"), Style::default().fg(DIM)),
                Span::styled(format!("{:>8}", "rtt"), Style::default().fg(DIM)),
            ])];
            for p in peers.iter().take((mesh_in.height as usize).saturating_sub(1)) {
                let here = target.as_deref() == Some(p.alias.as_str());
                let (dot, dc) = if !p.probed {
                    ("·", DIM)
                } else if p.up {
                    ("●", Color::Rgb(120, 220, 140))
                } else {
                    ("●", Color::Rgb(240, 72, 72))
                };
                l.push(Line::from(vec![
                    Span::styled(format!("{dot} "), Style::default().fg(dc)),
                    Span::styled(
                        format!("{:<14}", trunc(&p.alias, 14)),
                        Style::default().fg(if here { Color::Rgb(120, 200, 255) } else { Color::Gray }),
                    ),
                    Span::styled(format!("{:>10}", p.ip), Style::default().fg(DIM)),
                    Span::styled(
                        if !p.probed {
                            format!("{:>8}", "…")
                        } else if p.up {
                            format!("{:>7.0}ms", p.rtt_ms)
                        } else {
                            format!("{:>8}", "down")
                        },
                        Style::default().fg(if p.up { grad(p.rtt_ms / 200.0) } else { DIM }),
                    ),
                ]));
            }
            if peers.is_empty() {
                l.push(Line::from(Span::styled(
                    "no mesh peers in ~/.ssh/config",
                    Style::default().fg(Color::Rgb(240, 160, 90)),
                )));
            }
            f.render_widget(Paragraph::new(l), mesh_in);
        }

        // ── processes ─────────────────────────────────────────────────────────
        // Sorted against the local clone `s`, so self stays free to mutate for
        // the scroll bookkeeping just below.
        let sorted = sort_procs(&s, self.sort, self.desc, self.win);
        // Depth rides along even when the tree is off, so the row builder does
        // not need two shapes; it is simply 0 for every row.
        let procs: Vec<(&Value, usize)> = if self.tree {
            tree_order(&sorted)
        } else {
            sorted.iter().map(|p| (*p, 0usize)).collect()
        };
        // Follow the pid, not the row number. Re-sorting happens every tick and
        // the cursor must stay on the process the user chose, not on whatever
        // slid into that slot.
        if let Some(pid) = self.sel_pid {
            if let Some(i) = procs.iter().position(|(p, _)| num(p, "pid") as i64 == pid) {
                self.sel = i;
            }
        }
        let hint = format!(
            "{}{} · {} · {}←→ column · i inv · w win · t tree · enter details · k act · h help",
            self.sort.label(),
            if self.desc { "▼" } else { "▲" },
            self.win.label(),
            if self.tree { "tree · " } else { "" },
        );
        let proc_b = bbox("proc", &hint);
        let proc_in = proc_b.inner(rows[4]);
        f.render_widget(proc_b, rows[4]);

        // Keep the selection inside the viewport, scrolling only when it would
        // otherwise leave — a table that recentres on every tick is unreadable.
        let vis = (proc_in.height as usize).saturating_sub(1).max(1);
        // Declared units ride at the bottom of the same list, so the cursor
        // and the scroll window have to count them too — otherwise `v` shows
        // rows nothing can ever reach.
        let units = self.unit_rows(&s);
        let total = procs.len() + units.len();
        self.sel = self.sel.min(total.saturating_sub(1));
        if self.sel < self.offset {
            self.offset = self.sel;
        } else if self.sel >= self.offset + vis {
            self.offset = self.sel + 1 - vis;
        }
        if self.offset + vis > total {
            self.offset = total.saturating_sub(vis);
        }

        let w = self.win;
        let trows: Vec<Row> = procs
            .iter()
            .enumerate()
            .skip(self.offset)
            .take(vis)
            .map(|(i, (p, depth))| {
                let cpu = w.get(p, "cpu_pct");
                let memp = w.get(p, "mem_pct");
                let rss = w.get(p, "mem_rss_bytes");
                let rd = w.get(p, "read_bytes_per_s");
                let wr = w.get(p, "write_bytes_per_s");
                let rq = w.get(p, "runq_wait_pct");
                // The average columns are fixed windows, NOT the `w` window:
                // the point of showing them beside the live value is comparing
                // the three, which a column that moved with `w` could not do.
                let a = |win: &str, field: &str| avg_or(p, win, field);
                let prot = p.get("protected").and_then(|v| v.as_bool()).unwrap_or(false);
                let zombie = text(p, "state").starts_with('Z');
                // In tree mode the indent IS the parent/child relation, so it
                // goes in the name column where the eye already is.
                let name = format!(
                    "{}{}{}{}",
                    if self.tree && *depth > 0 { "  ".repeat(depth - 1) } else { String::new() },
                    if self.tree && *depth > 0 { "└ " } else { "" },
                    if prot { "🔒" } else { "" },
                    text(p, "name"),
                );
                let sel = i == self.sel;
                let base = if sel {
                    Style::default().bg(Color::Rgb(38, 48, 66)).add_modifier(Modifier::BOLD)
                } else if zombie {
                    // A zombie holds nothing but a pid and an exit code. It is
                    // never the thing eating the box, so it reads as debris.
                    Style::default().fg(Color::Rgb(240, 72, 72))
                } else if prot {
                    Style::default().fg(DIM)
                } else {
                    Style::default()
                };
                Row::new(vec![
                    Cell::from(format!("{}", num(p, "pid") as i64)).style(base.fg(if sel { Color::White } else { LABEL })),
                    Cell::from(text(p, "slice")).style(base.fg(if sel { Color::White } else { DIM })),
                    Cell::from(text(p, "user")).style(base.fg(if sel { Color::White } else { LABEL })),
                    Cell::from(name).style(base),
                    Cell::from(format!("{cpu:>5.1}")).style(base.fg(grad(cpu / 100.0))),
                    Cell::from(format!("{:>5.1}", a("10s", "cpu_pct"))).style(base.fg(grad(a("10s", "cpu_pct") / 100.0))),
                    Cell::from(format!("{:>5.1}", a("1m", "cpu_pct"))).style(base.fg(grad(a("1m", "cpu_pct") / 100.0))),
                    Cell::from(format!("{memp:>5.1}")).style(base.fg(grad(memp / 100.0))),
                    Cell::from(format!("{:>5.1}", a("10s", "mem_pct"))).style(base.fg(grad(a("10s", "mem_pct") / 100.0))),
                    Cell::from(format!("{:>5.1}", a("1m", "mem_pct"))).style(base.fg(grad(a("1m", "mem_pct") / 100.0))),
                    Cell::from(fmt_fixed(rss)).style(base.fg(Color::Gray)),
                    // null when the daemon could not read another user's
                    // smaps_rollup. A dash, not a zero — we do not know.
                    Cell::from(match p.get("mem_pss_bytes").and_then(|v| v.as_f64()) {
                        Some(v) => fmt_fixed(v),
                        None => "    —".into(),
                    })
                    .style(base.fg(Color::Rgb(150, 170, 200))),
                    Cell::from(fmt_bps(num(p, "net_rx_bytes_per_s"))).style(base.fg(Color::Rgb(120, 200, 255))),
                    Cell::from(fmt_bps(num(p, "net_tx_bytes_per_s"))).style(base.fg(Color::Rgb(240, 169, 66))),
                    Cell::from(fmt_bps(rd)).style(base.fg(Color::Rgb(120, 220, 140))),
                    Cell::from(fmt_bps(wr)).style(base.fg(Color::Rgb(220, 140, 240))),
                    Cell::from(format!("{rq:>5.2}")).style(base.fg(grad(rq / 20.0))),
                ])
            })
            .collect();

        // Everything a unit row can honestly say: it has no pid, no rss and no
        // rates. Blanks rather than zeroes — a zero here would read as a
        // measurement, and there is nothing being measured.
        let mut trows = trows;
        let ustart = self.offset.saturating_sub(procs.len());
        for (j, (name, scope, state)) in
            units.iter().enumerate().skip(ustart).take(vis.saturating_sub(trows.len()))
        {
            let sel = procs.len() + j == self.sel;
            let failed = state.starts_with("failed");
            let base = if sel {
                Style::default().bg(Color::Rgb(38, 48, 66)).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(DIM)
            };
            let sc = if failed { Color::Rgb(240, 72, 72) } else { Color::Rgb(150, 140, 110) };
            let mut cells = vec![
                Cell::from("  —").style(base),
                Cell::from(scope.clone()).style(base),
                Cell::from("—").style(base),
                Cell::from(format!("{}  {}", trunc(name, 34), state)).style(base.fg(sc)),
            ];
            cells.extend((0..13).map(|_| Cell::from("").style(base)));
            trows.push(Row::new(cells));
        }

        let hdr = |name: &'static str, k: Sort| -> Cell<'static> {
            if self.sort == k {
                Cell::from(format!("{name}{}", if self.desc { "▼" } else { "▲" }))
                    .style(Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD))
            } else {
                Cell::from(name).style(Style::default().fg(LABEL))
            }
        };
        let table = Table::new(
            trows,
            [
                Constraint::Length(7),  // PID
                Constraint::Length(9),  // SLICE
                Constraint::Length(8),  // USER
                Constraint::Min(12),    // PROGRAM
                Constraint::Length(5),  // CPU%
                Constraint::Length(5),  // C10s
                Constraint::Length(5),  // C60s
                Constraint::Length(5),  // MEM%
                Constraint::Length(5),  // M10s
                Constraint::Length(5),  // M60s
                Constraint::Length(5),  // RSS
                Constraint::Length(5),  // PSS
                Constraint::Length(6),  // D/s
                Constraint::Length(6),  // U/s
                Constraint::Length(6),  // R/s
                Constraint::Length(6),  // W/s
                Constraint::Length(5),  // RUNQ
            ],
        )
        .header(Row::new(vec![
            hdr("PID", Sort::Pid),
            hdr("SLICE", Sort::Slice),
            hdr("USER", Sort::User),
            hdr("PROGRAM", Sort::Name),
            hdr("CPU%", Sort::Cpu),
            hdr("C10s", Sort::C10s),
            hdr("C60s", Sort::C60s),
            hdr("MEM%", Sort::Mem),
            hdr("M10s", Sort::M10s),
            hdr("M60s", Sort::M60s),
            hdr("RSS", Sort::Mem),
            hdr("PSS", Sort::Pss),
            hdr("D/s", Sort::Net),
            hdr("U/s", Sort::Net),
            hdr("R/s", Sort::Disk),
            hdr("W/s", Sort::Disk),
            hdr("RUNQ", Sort::Runq),
        ]));
        f.render_widget(table, proc_in);

        // ── status line ───────────────────────────────────────────────────────
        let status = match &self.msg {
            Some((m, err)) => Line::from(Span::styled(
                format!(" {m}"),
                Style::default().fg(if *err { Color::Rgb(240, 72, 72) } else { Color::Rgb(120, 220, 140) }),
            )),
            None => Line::from(vec![
                Span::styled(
                    format!(" {} procs · showing {} values", procs.len(), self.win.label()),
                    Style::default().fg(LABEL),
                ),
                Span::styled(
                    "  · h keys · esc menu · ^c quits · drag to select text (no mouse capture)",
                    Style::default().fg(DIM),
                ),
            ]),
        };
        f.render_widget(Paragraph::new(status), rows[5]);

        // ── overlays ──────────────────────────────────────────────────────────
        match self.overlay {
            Overlay::Kill => self.render_kill(f, area),
            Overlay::Menu => self.render_menu(f, area),
            Overlay::Help => self.render_help(f, area),
            Overlay::Detail => self.render_detail(f, area),
            Overlay::Target => self.render_target(f, area),
            Overlay::None => {}
        }
    }
}

// ─────────────────────────────────── checks ───────────────────────────────────
// The two pieces here that are not just layout: the braille rasteriser (an
// off-by-one in the height mapping silently draws every graph one sub-row low)
// and the sort/window pair (a missing `avg` block must fall back to the instant
// value, not sort the process to the bottom as a zero).
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ←/→ walks the header left to right and wraps. If step() ever clamped
    // instead, the two ends of the header would be dead keys.
    #[test]
    fn arrows_walk_the_sort_columns_and_wrap() {
        assert_eq!(Sort::Cpu.step(1), Sort::C10s);
        assert_eq!(Sort::C10s.step(-1), Sort::Cpu);
        // the four averages sit between their live columns, in header order
        assert_eq!(Sort::C60s.step(1), Sort::Mem);
        assert_eq!(Sort::Mem.step(1), Sort::M10s);
        assert_eq!(Sort::M60s.step(1), Sort::Net);
        assert_eq!(Sort::Net.step(1), Sort::Disk);
        // slice sits where its column does, right after PID
        assert_eq!(Sort::Pid.step(1), Sort::Slice);
        // wrap both ways off the ends
        assert_eq!(SORT_ORDER[0].step(-1), SORT_ORDER[SORT_ORDER.len() - 1]);
        assert_eq!(SORT_ORDER[SORT_ORDER.len() - 1].step(1), SORT_ORDER[0]);
        // ←→ is a round trip, i.e. it does not also flip the direction
        for k in SORT_ORDER {
            assert_eq!(k.step(1).step(-1), k);
        }
    }

    // Esc must open the menu, never quit — the whole point of ^c/^d being the
    // only exit. A regression here silently makes Esc a way out again.
    #[test]
    fn esc_is_claimed_and_opens_the_menu_instead_of_quitting() {
        let mut m = Monitor::new();
        assert!(m.claims(KeyCode::Esc), "esc must not reach the frame's quit");
        assert!(!m.claims(KeyCode::Char('c')), "plain keys stay unclaimed while no modal is up");
        m.on_key(KeyCode::Esc);
        assert!(m.overlay == Overlay::Menu);
        assert!(!m.wants_quit());
        // While a modal is up it owns everything, so q closes it rather than
        // closing the program.
        assert!(m.claims(KeyCode::Char('q')));
        m.on_key(KeyCode::Char('q'));
        assert!(m.overlay == Overlay::None);
        assert!(!m.wants_quit());
    }

    // The menu's "quit" is the one path that may exit, and it can only do it
    // by asking the frame — a claimed key never reaches the frame's own quit.
    #[test]
    fn menu_quit_item_asks_the_frame_to_exit() {
        let mut m = Monitor::new();
        m.on_key(KeyCode::Esc);
        for _ in 0..MENU.len() - 1 {
            m.on_key(KeyCode::Down);
        }
        // Walked to the last entry, whatever the menu has grown to — the point
        // of the test is that quit exits, not where it happens to sit today.
        assert_eq!(MENU[m.menu_sel].0, "quit");
        m.on_key(KeyCode::Enter);
        assert!(m.wants_quit());
    }

    // RESTART rides the same mailbox as the signals but must not be sent as
    // one: the daemon branches on the literal word.
    #[test]
    fn restart_is_the_first_action_and_is_not_a_signal() {
        assert_eq!(ACTIONS[0].0, "RESTART");
        assert!(ACTIONS.iter().filter(|(n, _)| *n == "RESTART").count() == 1);
        // every other entry is a real signal name the daemon can map
        for (n, _) in ACTIONS.iter().skip(1) {
            assert!(n.chars().all(|c| c.is_ascii_uppercase()), "{n} is not a signal name");
        }
    }

    // The 10s/60s columns read fixed windows. If avg_or fell back to the live
    // value when a window exists, a spiking process would look sustained.
    #[test]
    fn average_columns_read_their_own_window() {
        let p: Value = serde_json::from_str(
            r#"{"cpu_pct": 90.0, "avg": {"10s": {"cpu_pct": 40.0}, "1m": {"cpu_pct": 5.0}}}"#,
        )
        .unwrap();
        assert_eq!(avg_or(&p, "10s", "cpu_pct"), 40.0);
        assert_eq!(avg_or(&p, "1m", "cpu_pct"), 5.0);
        // A window the daemon has not accumulated yet falls back to live
        // rather than showing a confident zero.
        assert_eq!(avg_or(&p, "15m", "cpu_pct"), 90.0);
    }

    const BLANK: char = '\u{2800}';

    #[test]
    fn braille_zero_is_blank_and_full_is_solid() {
        let z = braille_graph(&vec![0.0; 8], 100.0, 4, 2);
        assert_eq!(z.len(), 2);
        for line in &z {
            for sp in &line.spans {
                assert_eq!(sp.content.chars().next().unwrap(), BLANK);
            }
        }
        // Every dot set is U+28FF. A full-scale column must light the TOP row
        // too — that is the check that catches a height mapping that is short
        // by one sub-row, which looks plausible on screen but clips every peak.
        let f = braille_graph(&vec![100.0; 8], 100.0, 4, 2);
        for sp in &f[0].spans {
            assert_eq!(sp.content.chars().next().unwrap(), '\u{28FF}');
        }
    }

    #[test]
    fn braille_half_scale_fills_bottom_half_only() {
        let g = braille_graph(&vec![50.0; 4], 100.0, 2, 2);
        // rows=2 -> 8 sub-rows; 50% -> 4 lit from the bottom, so the top cell
        // row is empty and the bottom one is solid.
        for sp in &g[0].spans {
            assert_eq!(sp.content.chars().next().unwrap(), BLANK);
        }
        for sp in &g[1].spans {
            assert_eq!(sp.content.chars().next().unwrap(), '\u{28FF}');
        }
    }

    #[test]
    fn graph_right_aligns_short_history() {
        // Two samples in a 4-column (8-slot) graph must sit at the RIGHT edge,
        // so a freshly started dashboard grows in instead of stretching.
        let g = braille_graph(&[100.0, 100.0], 100.0, 4, 1);
        let chars: Vec<char> = g[0].spans.iter().map(|s| s.content.chars().next().unwrap()).collect();
        assert_eq!(chars[0], BLANK);
        assert_eq!(chars[2], BLANK);
        assert_eq!(chars[3], '\u{28FF}');
    }

    fn snap() -> Value {
        json!({"proc_table": [
            {"pid": 1, "name": "beta",  "user": "root",  "cpu_pct": 5.0, "mem_pct": 1.0,
             "avg": {"10s": {"cpu_pct": 80.0, "mem_pct": 3.0},
                     "1m":  {"cpu_pct":  2.0, "mem_pct": 40.0},
                     "15m": {"cpu_pct": 90.0}}},
            {"pid": 2, "name": "alpha", "user": "diego", "cpu_pct": 50.0, "mem_pct": 20.0}
        ]})
    }

    #[test]
    fn sorts_by_cpu_desc_and_inverts() {
        let s = snap();
        let d = sort_procs(&s, Sort::Cpu, true, Win::Now);
        assert_eq!(num(d[0], "pid") as i32, 2);
        let a = sort_procs(&s, Sort::Cpu, false, Win::Now);
        assert_eq!(num(a[0], "pid") as i32, 1);
    }

    #[test]
    fn window_uses_average_and_falls_back_when_absent() {
        let s = snap();
        // pid 1 is quiet now but a 90% hog over 15m; pid 2 has no avg block at
        // all and must fall back to its instant 50, not be treated as zero.
        let v = sort_procs(&s, Sort::Cpu, true, Win::M15);
        assert_eq!(num(v[0], "pid") as i32, 1);
        assert_eq!(Win::M15.get(v[1], "cpu_pct"), 50.0);
    }

    #[test]
    fn sorts_by_name_as_text() {
        let s = snap();
        let v = sort_procs(&s, Sort::Name, false, Win::Now);
        assert_eq!(text(v[0], "name"), "alpha");
    }

    // The four average columns rank on their own fixed window: asking for C60s
    // must order by the 1m average even while the display is showing "now".
    #[test]
    fn average_columns_rank_on_their_own_window_not_the_display_one() {
        let s = snap();
        // pid 1: 10s cpu 80 / 1m cpu 2. pid 2 has no avg block, so it falls
        // back to its instant 50 for both.
        assert_eq!(num(sort_procs(&s, Sort::C10s, true, Win::Now)[0], "pid") as i32, 1);
        assert_eq!(num(sort_procs(&s, Sort::C60s, true, Win::Now)[0], "pid") as i32, 2);
        // and `w` does not move them
        assert_eq!(num(sort_procs(&s, Sort::C60s, true, Win::M15)[0], "pid") as i32, 2);
        // mem averages read mem_pct, not the rss bytes the MEM% column sorts on
        assert_eq!(num(sort_procs(&s, Sort::M10s, true, Win::Now)[0], "pid") as i32, 2);
        assert_eq!(num(sort_procs(&s, Sort::M60s, true, Win::Now)[0], "pid") as i32, 1);
    }
}
