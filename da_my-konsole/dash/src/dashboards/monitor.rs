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
// It also gets data a TUI sampler would not have: the daemon keeps 1m/5m/15m
// rolling averages and run-queue wait PER PROCESS (the `w` key cycles them),
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

#[derive(Clone, Copy, PartialEq)]
enum Sort {
    Cpu,
    Mem,
    Disk,
    Pid,
    Name,
    User,
    Runq,
}

impl Sort {
    fn label(self) -> &'static str {
        match self {
            Sort::Cpu => "cpu",
            Sort::Mem => "mem",
            Sort::Disk => "disk",
            Sort::Pid => "pid",
            Sort::Name => "name",
            Sort::User => "user",
            Sort::Runq => "runq",
        }
    }
}

/// Which sample of a process to sort and display: the instant value the daemon
/// just measured, or one of the rolling averages it keeps. A 15m average is how
/// you tell a genuine hog from something that merely spiked while you looked.
#[derive(Clone, Copy, PartialEq)]
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
                Sort::Runq => win.get(p, "runq_wait_pct"),
                Sort::Pid => num(p, "pid"),
                Sort::Name | Sort::User => 0.0,
            }
        };
        let ord = match sort {
            // Text columns sort as text; everything else numerically.
            Sort::Name => text(a, "name").to_lowercase().cmp(&text(b, "name").to_lowercase()),
            Sort::User => text(a, "user").to_lowercase().cmp(&text(b, "user").to_lowercase()),
            _ => key(a).partial_cmp(&key(b)).unwrap_or(std::cmp::Ordering::Equal),
        };
        if desc { ord.reverse() } else { ord }
    });
    v
}

const SIGNALS: [(&str, &str); 6] = [
    ("TERM", "polite stop, the default"),
    ("INT", "as if you pressed ctrl-c"),
    ("HUP", "reload, or stop if unhandled"),
    ("QUIT", "stop and dump core"),
    ("STOP", "freeze, unignorable"),
    ("KILL", "unignorable, no cleanup"),
];

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
    mem_hist: Vec<f64>,
    rx_hist: Vec<f64>,
    tx_hist: Vec<f64>,
    psi_hist: Vec<f64>,

    sort: Sort,
    desc: bool,
    win: Win,
    sel: usize,
    offset: usize,
    killing: Option<(i32, String)>,
    msg: Option<(String, bool)>,
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
            mem_hist: vec![],
            rx_hist: vec![],
            tx_hist: vec![],
            psi_hist: vec![],
            sort: Sort::Cpu,
            desc: true,
            win: Win::Now,
            sel: 0,
            offset: 0,
            killing: None,
            msg: None,
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
            Ok(()) => (format!("SIG{sig} → pid {pid} queued for the daemon"), false),
            Err(e) => (format!("could not write {path}: {e}"), true),
        });
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
        let s = read_json(&snapshot_path());
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

    fn on_key(&mut self, k: KeyCode) {
        let n = arr(&self.snap, "proc_table").len();
        // While the kill menu is open it swallows the keys, so a stray 'c'
        // cannot silently re-sort the list under the pid you are aiming at.
        if let Some((pid, name)) = self.killing.clone() {
            match k {
                KeyCode::Char(c) if c.is_ascii_digit() => {
                    let i = c.to_digit(10).unwrap_or(0) as usize;
                    if i >= 1 && i <= SIGNALS.len() {
                        let sig = SIGNALS[i - 1].0;
                        self.request_kill(pid, sig);
                        self.killing = None;
                    }
                }
                KeyCode::Char('x') | KeyCode::Backspace => {
                    self.msg = Some((format!("kill cancelled — {name} ({pid}) untouched"), false));
                    self.killing = None;
                }
                _ => {}
            }
            return;
        }
        match k {
            KeyCode::Down => self.sel = (self.sel + 1).min(n.saturating_sub(1)),
            KeyCode::Up => self.sel = self.sel.saturating_sub(1),
            KeyCode::PageDown => self.sel = (self.sel + 10).min(n.saturating_sub(1)),
            KeyCode::PageUp => self.sel = self.sel.saturating_sub(10),
            KeyCode::Home => self.sel = 0,
            KeyCode::End => self.sel = n.saturating_sub(1),
            KeyCode::Char('c') => self.sort = Sort::Cpu,
            KeyCode::Char('m') => self.sort = Sort::Mem,
            KeyCode::Char('d') => self.sort = Sort::Disk,
            KeyCode::Char('p') => self.sort = Sort::Pid,
            KeyCode::Char('n') => self.sort = Sort::Name,
            KeyCode::Char('u') => self.sort = Sort::User,
            KeyCode::Char('g') => self.sort = Sort::Runq,
            KeyCode::Char('i') => self.desc = !self.desc,
            KeyCode::Char('w') => self.win = self.win.next(),
            KeyCode::Char('k') => {
                // Copy what we need out of the borrow before touching self:
                // the sorted Vec borrows self.snap, so self.msg/self.killing
                // cannot be assigned while it is still alive.
                let picked = {
                    let procs = sort_procs(&self.snap, self.sort, self.desc, self.win);
                    procs.get(self.sel).map(|p| {
                        (
                            num(p, "pid") as i32,
                            text(p, "name"),
                            p.get("protected").and_then(|v| v.as_bool()).unwrap_or(false),
                            text(p, "protected_reason"),
                        )
                    })
                };
                if let Some((pid, name, prot, why)) = picked {
                    // The daemon refuses these anyway; saying so here means the
                    // answer arrives before the keystroke, not after a silent
                    // no-op the user has to go read a log to explain.
                    if prot {
                        let why = if why.is_empty() { "protected slice".to_string() } else { why };
                        self.msg = Some((format!("{name} ({pid}) is protected — {why}"), true));
                    } else {
                        self.msg = None;
                        self.killing = Some((pid, name));
                    }
                }
            }
            _ => {}
        }
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        let s = self.snap.clone();

        let rows = Layout::vertical([
            Constraint::Length(1),  // header
            Constraint::Length(11), // cpu
            Constraint::Length(13), // mem | net | psi
            Constraint::Min(6),     // procs
            Constraint::Length(1),  // status
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
                    let bw = (ca.width as usize).saturating_sub(9);
                    let mut sp = vec![Span::styled(format!("{i:>2} "), Style::default().fg(LABEL))];
                    sp.extend(meter(bw, v / 100.0, "").spans);
                    sp.push(Span::styled(format!(" {v:>3.0}%"), Style::default().fg(grad(v / 100.0))));
                    Line::from(sp)
                })
                .collect();
            f.render_widget(Paragraph::new(lines), *ca);
        }

        // ── mem | net | psi ───────────────────────────────────────────────────
        let mid = Layout::horizontal([
            Constraint::Percentage(44),
            Constraint::Percentage(28),
            Constraint::Percentage(28),
        ])
        .split(rows[2]);

        // memory
        let mem_b = bbox("mem", "");
        let mem_in = mem_b.inner(mid[0]);
        f.render_widget(mem_b, mid[0]);
        let bw = (mem_in.width as usize).saturating_sub(22);
        let mut ml: Vec<Line> = vec![];
        let bar = |label: &str, pct: f64, txt: String| -> Line<'static> {
            let mut sp = vec![Span::styled(format!("{label:<6}"), Style::default().fg(LABEL))];
            sp.extend(meter(bw, pct / 100.0, "").spans);
            sp.push(Span::styled(format!(" {txt}"), Style::default().fg(Color::Gray)));
            Line::from(sp)
        };
        ml.push(bar(
            "ram",
            num(&s, "mem"),
            format!("{}/{}", fmt_gib(num(&s, "mem_detail.used")), fmt_gib(num(&s, "mem_detail.total"))),
        ));
        ml.push(bar(
            "swap",
            num(&s, "swap"),
            format!("{}/{}", fmt_gib(num(&s, "swap_detail.used")), fmt_gib(num(&s, "swap_detail.total"))),
        ));
        // The user slice's own cap is what actually decides who gets OOM-killed
        // on this machine — RAM% can look calm while the slice is at its limit.
        ml.push(bar(
            "slice",
            num(&s, "slice_pct"),
            format!("{}/{}", fmt_gib(num(&s, "slice_gib")), fmt_gib(num(&s, "slice_max_gib"))),
        ));
        ml.push(Line::from(vec![
            Span::styled("  cached ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(num(&s, "mem_detail.cached")), Style::default().fg(Color::Gray)),
            Span::styled("  buffers ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(num(&s, "mem_detail.buffers")), Style::default().fg(Color::Gray)),
            Span::styled("  avail ", Style::default().fg(LABEL)),
            Span::styled(fmt_gib(num(&s, "mem_detail.available")), Style::default().fg(Color::Rgb(120, 200, 255))),
        ]));
        ml.push(Line::from(Span::styled("", Style::default())));
        for dk in arr(&s, "disks") {
            let pct = num(dk, "pct");
            let mount = text(dk, "mount");
            let mut sp = vec![Span::styled(
                format!("{:<6}", mount.chars().rev().take(6).collect::<String>().chars().rev().collect::<String>()),
                Style::default().fg(LABEL),
            )];
            sp.extend(meter(bw, pct / 100.0, "").spans);
            sp.push(Span::styled(
                format!(" {}/{}", fmt_gib(num(dk, "used_gib")), fmt_gib(num(dk, "total_gib"))),
                Style::default().fg(Color::Gray),
            ));
            ml.push(Line::from(sp));
        }
        ml.push(Line::from(vec![
            Span::styled("  disk  ", Style::default().fg(LABEL)),
            Span::styled(format!("read {}", fmt_rate_mb(num(&s, "disk_r"))), Style::default().fg(Color::Rgb(120, 220, 140))),
            Span::styled("  ", Style::default()),
            Span::styled(format!("write {}", fmt_rate_mb(num(&s, "disk_w"))), Style::default().fg(Color::Rgb(220, 140, 240))),
        ]));
        f.render_widget(Paragraph::new(ml), mem_in);

        // network
        let net_b = bbox("net", "");
        let net_in = net_b.inner(mid[1]);
        f.render_widget(net_b, mid[1]);
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

        // PSI — the box that matters most on this machine. systemd-oomd watches
        // MEMORY pressure only; the 2026-08-22 freeze was IO-bound, invisible to
        // it, and only freeze-guard's voters covered it. So show both: the raw
        // some/full averages, and which of the guard's voters are armed.
        let psi_b = bbox("psi", "");
        let psi_in = psi_b.inner(mid[2]);
        f.render_widget(psi_b, mid[2]);
        let mut pl: Vec<Line> = vec![Line::from(vec![
            Span::styled("        10s    60s   300s", Style::default().fg(LABEL)),
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
                pl.push(Line::from(vec![
                    Span::styled(
                        format!("{:<4}", if band == "some" { short } else { "" }),
                        Style::default().fg(Color::Rgb(120, 200, 255)),
                    ),
                    Span::styled(format!("{:<4}", band), Style::default().fg(LABEL)),
                    Span::styled(format!("{v10:>5.2}"), Style::default().fg(grad(v10 / scale))),
                    Span::styled(format!("{v60:>7.2}"), Style::default().fg(grad(v60 / scale))),
                    Span::styled(format!("{v300:>7.2}"), Style::default().fg(grad(v300 / scale))),
                ]));
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

        // ── processes ─────────────────────────────────────────────────────────
        // Sorted against the local clone `s`, so self stays free to mutate for
        // the scroll bookkeeping just below.
        let procs = sort_procs(&s, self.sort, self.desc, self.win);
        let hint = format!(
            "{}{} · {} · c/m/d/g/p/n/u sort · i inv · w win · k kill",
            self.sort.label(),
            if self.desc { "▼" } else { "▲" },
            self.win.label()
        );
        let proc_b = bbox("proc", &hint);
        let proc_in = proc_b.inner(rows[3]);
        f.render_widget(proc_b, rows[3]);

        // Keep the selection inside the viewport, scrolling only when it would
        // otherwise leave — a table that recentres on every tick is unreadable.
        let vis = (proc_in.height as usize).saturating_sub(1).max(1);
        self.sel = self.sel.min(procs.len().saturating_sub(1));
        if self.sel < self.offset {
            self.offset = self.sel;
        } else if self.sel >= self.offset + vis {
            self.offset = self.sel + 1 - vis;
        }
        if self.offset + vis > procs.len() {
            self.offset = procs.len().saturating_sub(vis);
        }

        let w = self.win;
        let trows: Vec<Row> = procs
            .iter()
            .enumerate()
            .skip(self.offset)
            .take(vis)
            .map(|(i, p)| {
                let cpu = w.get(p, "cpu_pct");
                let memp = w.get(p, "mem_pct");
                let rss = w.get(p, "mem_rss_bytes");
                let rd = w.get(p, "read_bytes_per_s");
                let wr = w.get(p, "write_bytes_per_s");
                let rq = w.get(p, "runq_wait_pct");
                let prot = p.get("protected").and_then(|v| v.as_bool()).unwrap_or(false);
                let name = text(p, "name");
                let sel = i == self.sel;
                let base = if sel {
                    Style::default().bg(Color::Rgb(38, 48, 66)).add_modifier(Modifier::BOLD)
                } else if prot {
                    Style::default().fg(DIM)
                } else {
                    Style::default()
                };
                Row::new(vec![
                    Cell::from(format!("{}", num(p, "pid") as i64)).style(base.fg(if sel { Color::White } else { LABEL })),
                    Cell::from(text(p, "user")).style(base.fg(if sel { Color::White } else { LABEL })),
                    Cell::from(format!("{}{}", if prot { "🔒" } else { "" }, name)).style(base),
                    Cell::from(format!("{cpu:>5.1}")).style(base.fg(grad(cpu / 100.0))),
                    Cell::from(format!("{memp:>5.1}")).style(base.fg(grad(memp / 100.0))),
                    Cell::from(fmt_bytes_short(rss)).style(base.fg(Color::Gray)),
                    Cell::from(fmt_bps(rd)).style(base.fg(Color::Rgb(120, 220, 140))),
                    Cell::from(fmt_bps(wr)).style(base.fg(Color::Rgb(220, 140, 240))),
                    Cell::from(format!("{rq:>5.2}")).style(base.fg(grad(rq / 20.0))),
                ])
            })
            .collect();

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
                Constraint::Length(8),
                Constraint::Length(10),
                Constraint::Min(16),
                Constraint::Length(6),
                Constraint::Length(6),
                Constraint::Length(7),
                Constraint::Length(7),
                Constraint::Length(7),
                Constraint::Length(6),
            ],
        )
        .header(Row::new(vec![
            hdr("PID", Sort::Pid),
            hdr("USER", Sort::User),
            hdr("PROGRAM", Sort::Name),
            hdr("CPU%", Sort::Cpu),
            hdr("MEM%", Sort::Mem),
            hdr("RSS", Sort::Mem),
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
                Span::styled("  · drag to select text (no mouse capture)", Style::default().fg(DIM)),
            ]),
        };
        f.render_widget(Paragraph::new(status), rows[4]);

        // ── kill menu ─────────────────────────────────────────────────────────
        if let Some((pid, name)) = self.killing.clone() {
            let h = SIGNALS.len() as u16 + 4;
            let wdt = 54u16.min(area.width.saturating_sub(4));
            let x = area.x + (area.width.saturating_sub(wdt)) / 2;
            let y = area.y + (area.height.saturating_sub(h)) / 2;
            let popup = Rect { x, y, width: wdt, height: h };
            f.render_widget(Clear, popup);
            let b = Block::default()
                .borders(Borders::ALL)
                .border_type(BorderType::Rounded)
                .border_style(Style::default().fg(Color::Rgb(240, 72, 72)))
                .title(Line::from(Span::styled(
                    "┤ signal ├",
                    Style::default().fg(Color::Rgb(240, 72, 72)).add_modifier(Modifier::BOLD),
                )));
            let inner = b.inner(popup);
            f.render_widget(b, popup);
            let mut lines = vec![
                Line::from(vec![
                    Span::styled(name.clone(), Style::default().fg(Color::White).add_modifier(Modifier::BOLD)),
                    Span::styled(format!("  pid {pid}"), Style::default().fg(LABEL)),
                ]),
                Line::from(Span::raw("")),
            ];
            for (i, (sig, what)) in SIGNALS.iter().enumerate() {
                lines.push(Line::from(vec![
                    Span::styled(format!(" {} ", i + 1), Style::default().fg(Color::Black).bg(Color::Rgb(120, 200, 255))),
                    Span::styled(format!(" SIG{sig:<5}"), Style::default().fg(Color::White)),
                    Span::styled(*what, Style::default().fg(LABEL)),
                ]));
            }
            lines.push(Line::from(Span::styled(
                " x cancel",
                Style::default().fg(DIM),
            )));
            f.render_widget(Paragraph::new(lines), inner);
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
            {"pid": 1, "name": "beta",  "user": "root",  "cpu_pct": 5.0,
             "avg": {"15m": {"cpu_pct": 90.0}}},
            {"pid": 2, "name": "alpha", "user": "diego", "cpu_pct": 50.0}
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
}
