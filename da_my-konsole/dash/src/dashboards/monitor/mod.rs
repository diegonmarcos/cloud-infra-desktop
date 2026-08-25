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

/// What the `k` menu can send. RESTART is first because it is the thing people
/// actually want most of the time — a wedged process put back rather than a
/// hole where it used to be — and because listing it beside the signals is the
/// only way anyone discovers the daemon grew the verb.
///
/// It is not a signal: the daemon restarts a user systemd unit through
/// systemctl when the pid belongs to one, and otherwise re-execs its argv. The
/// blurb says which, because "restart" quietly meaning two different things is
/// worse than saying so.

// ── the parts of this dashboard that are their own concern ─────────────
// Split out because a four-thousand-line file is not a module, it is a
// directory that has not happened yet. Each is testable on its own and none
// of them knows about the others.
mod data;
mod draw;
mod export;
mod fmt;
mod sort;

// Re-imported so a view still says `num(&s, "cpu")`: the split is for
// organising the source, not for making every call site longer.
use data::{arr, kill_path, now_secs, num, read_json, snapshot_path, text, HIST};
use draw::{bbox, braille_graph, grad, meter, tabbox, DIM, GRAPH_FLOOR, LABEL};
use export::{exe_dir, export_snapshot, open_dir, proc_comm};
use fmt::{
    fmt_bps, fmt_bytes_short, fmt_fixed, fmt_g, fmt_gib, fmt_mem_cell, fmt_rate_mb, fmt_uptime,
    push, trunc, z, zp,
};
use sort::{avg_or, num_opt, sort_procs, tree_order, Sort, Win, SORT_ORDER};

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

/// The `x` menu: things that give memory back, in increasing order of how
/// much they disturb.
///
/// Every one of them is a request on the same mailbox the signals use, so the
/// daemon applies the same protected-slice policy to all of them. The panel
/// decides nothing.
const FREE: [(&str, &str, &str); 3] = [
    (
        "REAP",
        "reap zombies",
        "SIGCHLD to each zombie's parent — one cannot be killed, only collected",
    ),
    (
        "RECLAIM",
        "reclaim session memory",
        "push this session's cold pages out — scoped, not system-wide drop_caches",
    ),
    (
        "ORPHANS",
        "list lost processes",
        "filter to processes reparented to init — look first, then k them",
    ),
];

/// The three things the big box can be. Naming them in the frame is the only
/// way anyone finds out the other two exist.
/// Keys the FRAME handles before a dashboard ever sees them.
///
/// frame.rs takes r and a for refresh and auto-refresh unless the dashboard
/// claims them, and it advertises both in its own header line. Binding one of
/// these in a view produces a key that is listed everywhere and works nowhere —
/// which is exactly what "about a" did. The test at the bottom of this file
/// fails if anything here is ever bound again.
const FRAME_RESERVED: &[char] = &['r', 'a'];

/// The sort columns reachable by a single key.
///
/// PID is deliberately NOT here: 'p' is the proc tab, and a key that sorts in
/// one mode and switches view in another is exactly the ambiguity this table
/// exists to prevent. ←/→ still walks onto PID like every other column.
///
/// ONE table: the handler dispatches from it and the help renders from it, so
/// a key cannot be documented and unhandled, or handled and undocumented.
const SORT_KEYS: &[(char, Sort, &str)] = &[
    ('c', Sort::Cpu, "cpu"),
    ('m', Sort::Mem, "memory %"),
    ('d', Sort::Disk, "disk"),
    ('g', Sort::Runq, "run-queue wait"),
    ('n', Sort::Name, "name"),
    ('u', Sort::User, "user"),
    ('e', Sort::Net, "network"),
    ('s', Sort::Slice, "slice"),
];

/// Everything else this dashboard binds: key, section, what it does.
///
/// The views live in VIEW_TABS and the sorts in SORT_KEYS because those two
/// tables are also the dispatch; this is the remainder, and the help is built
/// from all three rather than written a second time beside them.
const OTHER_KEYS: &[(&str, &str, &str)] = &[
    ("sorting", "← →", "move the sort to the next column, glances style"),
    ("sorting", "", "← → also reach C10s C60s M10s M60s and PSS"),
    ("sorting", "i", "invert the direction"),
    ("sorting", "w", "cycle the CPU%/MEM% window: now → 1m → 5m → 15m"),
    ("acting", "enter", "full disclosure — command, tree, cpu, mem, io, cgroup"),
    ("acting", "k", "act on it — restart, or any of the signals"),
    // "modal" entries are scoped to an overlay, so they may reuse a
    // top-level key: `o` opens a folder inside the detail view and switches
    // tab outside it, and the two can never both be live. The collision test
    // skips this section for that reason.
    ("modal", "o", "in the detail view: open the binary's folder"),
    ("modal", ".", "in the files tab: show or hide dotfiles"),
    ("acting", "x", "free memory — reap zombies, reclaim, find orphans"),
    ("acting", "E", "export THIS machine — {host}-{user}-{time}.json, .yaml, .md"),
    ("acting", "A", "export all — the same, with every fleet peer folded in"),
    ("moving", "↑ ↓", "move the cursor through the list"),
    ("moving", "pgup pgdn", "ten rows at a time"),
    ("moving", "home end", "first / last row"),
    ("leaving", "esc", "open the menu — it does NOT quit"),
    ("leaving", "h ? F1", "this page"),
    ("leaving", "ctrl-c ctrl-d", "quit. the only keys that do"),
];

const VIEW_TABS: &[(&str, char)] = &[
    ("proc", 'p'),
    ("tree", 't'),
    ("zombies", 'z'),
    ("containers-c", 'o'),
    ("containers-i", 'I'),
    ("fleet", 'f'),
    ("history", 'y'),
    ("files", 'F'),
    // 'b', not 'a': the frame owns r and a for refresh/auto and advertises
    // them in its own header, so a view key named 'a' silently never arrives.
    ("about", 'b'),
];

/// `tree -L 4` over the home directory, or the nearest thing available.
///
/// Shelled out rather than walked here: tree(1) already draws the box-drawing
/// prefixes this panel wants, and reimplementing that to avoid one process is
/// work for no benefit. find(1) is the fallback for a box without tree, with a
/// flat listing — less pretty, still the answer.
///
/// Bounded on purpose. -L 4 because past four levels a home directory is
/// mostly node_modules and .git objects, and the output is capped because a
/// tree with a million entries is not a view, it is a hang.
fn file_tree(hidden: bool) -> [Vec<String>; 4] {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
    // -d directories only, -f full paths, -i no indentation. One run, split by
    // depth afterwards — four separate `tree -L n` runs would walk the same
    // directories four times and produce four nested copies of each other.
    let mut args: Vec<&str> = vec!["-d", "-f", "-i", "-L", "4", "--noreport"];
    if hidden {
        args.push("-a");
    }
    // The four directories that turn a home tree into a hundred thousand
    // entries of nothing anybody opened this to see.
    args.extend(["-I", ".git|node_modules|.cache|target"]);
    args.push(&home);

    let out = std::process::Command::new("tree").args(&args).output();
    // The OUTPUT is the signal, not the exit code: tree returns 2 whenever any
    // directory could not be opened, which in a home directory is routine and
    // not a failure — it still printed everything else.
    let text = match out {
        Ok(o) if !o.stdout.is_empty() => String::from_utf8_lossy(&o.stdout).into_owned(),
        _ => {
            let mut f: Vec<String> = vec!["-maxdepth".into(), "4".into(), "-type".into(), "d".into()];
            if !hidden {
                f.extend(["-not".into(), "-path".into(), "*/.*".into()]);
            }
            std::process::Command::new("find")
                .arg(&home)
                .args(&f)
                .output()
                .ok()
                .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
                .unwrap_or_default()
        }
    };

    let mut levels: [Vec<String>; 4] = Default::default();
    for line in text.lines() {
        // A symlinked directory prints as "path -> target"; the path is what
        // this view is about.
        let path = line.split(" -> ").next().unwrap_or(line).trim_end_matches('/');
        let Some(rel) = path.strip_prefix(&home).map(|r| r.trim_start_matches('/')) else {
            continue;
        };
        if rel.is_empty() {
            continue; // home itself
        }
        let depth = rel.matches('/').count();
        if depth < 4 {
            levels[depth].push(rel.to_string());
        }
    }
    levels
}

/// Which slot in the strip a view sits in, by name.
///
/// Not a hard-coded number at each call site: inserting containers-i shifted
/// three of them and every one would have highlighted the wrong tab, silently.
/// The name is the identity; the position is a detail of the table.
fn tab(name: &str) -> usize {
    VIEW_TABS.iter().position(|(n, _)| *n == name).unwrap_or(0)
}

/// What a container row can be ranked by, and how to read the value out.
///
/// docker renders these as strings ("12.34%", "469.7MiB / 7.595GiB"), which is
/// what the table shows; ranking needs a number, so each column says how to
/// get one from its own text. ←/→ walks this list the way it walks the process
/// header.
const CTR_SORT: &[(&str, &str)] = &[
    ("CPU%", "cpu"),
    ("MEM%", "mem_pct"),
    ("MEM USED", "mem"),
    ("CONTAINER", "name"),
    ("BLOCK I/O", "block"),
    ("NET I/O", "net"),
    ("PIDS", "pids"),
    ("ON DISK", "image_size"),
];

/// What an image row can be ranked by. Same idea as CTR_SORT: the strings
/// docker renders are what the table shows, and each column says how to get a
/// number out of its own text.
const IMG_SORT: &[(&str, &str)] = &[
    ("SIZE", "size"),
    ("CREATED", "created"),
    ("IMAGE", "repo"),
];

/// docker's MemUsage is "469.7MiB / 7.595GiB" — used on the left of the
/// slash, the limit on the right. Two different questions in one cell: what a
/// container is using, and what it is allowed. They get a column each, and
/// splitting them is what makes "rank by memory used" possible at all.
fn ctr_mem(v: &str) -> (String, String) {
    match v.split_once('/') {
        Some((a, b)) => (a.trim().to_string(), b.trim().to_string()),
        // No slash means no limit was set, which since the ceilings came off
        // is the normal case: it is all usage.
        None => (v.trim().to_string(), String::new()),
    }
}

/// "12 hours ago" / "3 days ago" as seconds, so CREATED ranks by age rather
/// than alphabetically — where "3 days" would sort before "3 hours".
fn age_secs(v: &str) -> f64 {
    let n: f64 = v
        .split_whitespace()
        .next()
        .and_then(|x| x.parse().ok())
        .unwrap_or(0.0);
    let unit = v.split_whitespace().nth(1).unwrap_or("");
    n * if unit.starts_with("second") {
        1.0
    } else if unit.starts_with("minute") {
        60.0
    } else if unit.starts_with("hour") {
        3600.0
    } else if unit.starts_with("day") {
        86_400.0
    } else if unit.starts_with("week") {
        604_800.0
    } else if unit.starts_with("month") {
        2_592_000.0
    } else if unit.starts_with("year") {
        31_536_000.0
    } else {
        0.0
    }
}

/// The first number in a docker-rendered field. "469.7MiB / 7.595GiB" ranks by
/// what the container is using, not by its limit; "12.34%" ranks by 12.34.
fn ctr_num(v: &str) -> f64 {
    let mut out = String::new();
    for c in v.chars() {
        if c.is_ascii_digit() || c == '.' {
            out.push(c);
        } else if !out.is_empty() {
            break;
        }
    }
    let n: f64 = out.parse().unwrap_or(0.0);
    // A bare number followed by a unit has to be scaled or 900kB outranks 5GB.
    let rest = v.trim_start_matches(|c: char| c.is_ascii_digit() || c == '.');
    let mult = if rest.starts_with("GiB") || rest.starts_with("GB") {
        1_073_741_824.0
    } else if rest.starts_with("MiB") || rest.starts_with("MB") {
        1_048_576.0
    } else if rest.starts_with("kB") || rest.starts_with("KiB") {
        1024.0
    } else {
        1.0
    };
    n * mult
}

/// What can be done to a container. No `rm`: stopping one is reversible and
/// removing one is not, and a keystroke is the wrong weight for that.
const CTR_ACTIONS: [(&str, &str); 5] = [
    ("restart", "stop it and bring it back"),
    ("stop", "take it down"),
    ("start", "bring it up"),
    ("pause", "freeze it, keeping its memory"),
    ("unpause", "thaw one you froze"),
];

/// What can be done to an image. `rm` is here because an unused image is dead
/// weight and removing it is the point of looking — docker itself refuses if a
/// container still references it, which is the guard.
const IMG_ACTIONS: [(&str, &str); 2] = [
    ("pull", "fetch the current version of this tag"),
    ("rm", "delete it — refused while a container uses it"),
];

/// One row under `v`: either a group heading or a declared unit.
#[derive(Clone, Debug)]
struct UnitRow {
    heading: Option<&'static str>,
    name: String,
    scope: String,
    state: String,
}

/// What the unit modal can ask systemd to do. Deliberately the four verbs a
/// person reaches for and no more — `enable` changes what happens at the NEXT
/// boot rather than now, which is a different kind of decision and does not
/// belong on a key you press while looking at a dead service.
const UNIT_ACTIONS: [(&str, &str); 4] = [
    ("start", "bring it up now"),
    ("restart", "stop it and bring it back"),
    ("stop", "take it down"),
    ("reset-failed", "clear the failed state so it can start again"),
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
    /// The `x` menu of memory-freeing tools.
    Free,
    /// start/stop/restart a declared unit the cursor is parked on.
    Unit,
    /// One machine's totals, opened from the fleet view.
    Machine,
    /// One container, with the verbs that act on it.
    Ctr,
    /// One image, with the verbs that act on it.
    Img,
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
    /// `f`: the proc area becomes one row per mesh peer.
    fleet: bool,
    /// `z`: only the processes nothing is looking after.
    zombies: bool,
    /// `y`: what this machine did over the last day.
    history: bool,
    /// `o`: containers and what they are using.
    docker: bool,
    /// `I`: the images on the box, running or not.
    images: bool,
    /// `F`: the home directory as a tree.
    files: bool,
    /// `.` inside the files tab: whether dotfiles are in it.
    files_hidden: bool,
    /// The rendered tree, cached. `tree -L 4` over a home directory walks tens
    /// of thousands of inodes — running it on a 1s render loop would make this
    /// panel the most expensive thing on the machine. It is built when the tab
    /// is opened and when the dotfile toggle flips, and not otherwise.
    files_cache: [Vec<String>; 4],
    files_scroll: u16,
    /// Which column containers-c ranks by, and which way.
    ctr_sort: usize,
    ctr_desc: bool,
    /// Same for containers-i.
    img_sort: usize,
    img_desc: bool,
    /// The container the detail modal is pinned to, by NAME. Same reason the
    /// process modal pins a pid: the list re-ranks every tick and the modal is
    /// about the container you chose, not about row 7.
    ctr_pin: Option<String>,
    img_pin: Option<String>,
    /// `a`: the static facts — what this machine IS, not what it is doing.
    about: bool,
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
    free_sel: usize,
    unit_sel: usize,
    /// Alias of the peer the Machine modal is describing.
    machine: Option<String>,
    /// The pid the detail modal was opened on, pinned. The modal is about
    /// that process; the list underneath re-sorts every tick.
    detail_pid: Option<i32>,
    /// (name, scope) of the unit the Unit modal is acting on.
    acting_unit: Option<(String, String)>,
    /// `x` → "list lost processes": filter the table down to orphans.
    orphans: bool,
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
            fleet: false,
            zombies: false,
            history: false,
            docker: false,
            images: false,
            files: false,
            files_hidden: false,
            files_cache: Default::default(),
            files_scroll: 0,
            ctr_sort: 0,
            ctr_desc: true,
            img_sort: 0,
            img_desc: true,
            ctr_pin: None,
            img_pin: None,
            about: false,
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
            free_sel: 0,
            unit_sel: 0,
            machine: None,
            detail_pid: None,
            acting_unit: None,
            orphans: false,
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
                match sig {
                    // Addressed to the machine, not a pid — saying "pid 0"
                    // here would be technically true and completely useless.
                    "REAP" => "reap → queued: SIGCHLD to every zombie's parent".to_string(),
                    "RECLAIM" => "reclaim → queued: pushing this session's cold pages out".to_string(),
                    "RESTART" => format!("restart → pid {pid} queued for the daemon"),
                    _ => format!("SIG{sig} → pid {pid} queued for the daemon"),
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
                format!(" {} / {}", fmt_g(used), fmt_g(size)),
                Style::default().fg(Color::Gray),
            ));
            l.push(Line::from(sp));
            // Allocated-but-unused chunks are the classic btrfs surprise: the
            // pool can report free space that no allocation can reach until a
            // balance runs, so the two figures are shown apart.
            l.push(Line::from(vec![
                Span::styled("  data ", Style::default().fg(LABEL)),
                Span::styled(
                    format!("{}/{}", fmt_g(num(pool, "data_used")), fmt_g(num(pool, "data_total"))),
                    Style::default().fg(Color::Gray),
                ),
                Span::styled("  meta ", Style::default().fg(LABEL)),
                Span::styled(
                    format!("{}/{}", fmt_g(num(pool, "meta_used")), fmt_g(num(pool, "meta_total"))),
                    Style::default().fg(Color::Gray),
                ),
                Span::styled("  unalloc ", Style::default().fg(LABEL)),
                Span::styled(fmt_g((size - alloc).max(0.0)), Style::default().fg(Color::Rgb(120, 200, 255))),
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
                        format!("  {:>3.0}% of {}", refer / limit * 100.0, fmt_g(limit)),
                        Style::default().fg(grad(refer / limit)),
                    )
                } else {
                    Span::styled("     —", Style::default().fg(DIM))
                };
                l.push(Line::from(vec![
                    Span::styled(format!("  {short:<20}"), Style::default().fg(Color::Gray)),
                    Span::styled(format!("{:>9}", fmt_g(refer)), Style::default().fg(grad(refer / size))),
                    Span::styled(format!("{:>9}", fmt_g(excl)), Style::default().fg(Color::Rgb(140, 150, 170))),
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

    /// The peers you can actually switch TO. "this machine" is already the
    /// first row of the picker as the local option, so listing it again among
    /// the ssh targets would offer to ssh to yourself — and, worse, would put
    /// the drawn list and the picked index one apart.
    fn selectable_peers(mesh: &crate::dashboards::mesh::Mesh) -> Vec<crate::dashboards::mesh::Peer> {
        mesh.list().into_iter().filter(|p| !p.local).collect()
    }

    /// Pick the machine this dashboard measures: this one, or a mesh peer
    /// read over ssh. Peers that did not answer their last probe are still
    /// listed and still selectable — "unreachable" is a probe result, not a
    /// permission, and the ssh attempt gives a better error than we can.
    fn render_target(&self, f: &mut Frame, area: Rect) {
        let accent = Color::Rgb(120, 200, 255);
        let peers = Self::selectable_peers(&self.mesh);
        let cur = self.mesh.target();
        let inner = Self::modal(f, area, 84, peers.len() as u16 + 6, "measure which machine", accent);
        let mut l: Vec<Line> = vec![];
        let mut row = |i: usize, mark: bool, name: String, note: String, style: Style| {
            let sel = i == self.target_sel;
            l.push(Line::from(vec![
                Span::styled(
                    if sel { "▶ " } else { "  " },
                    Style::default().fg(accent),
                ),
                Span::styled(if mark { "● " } else { "  " }, Style::default().fg(Color::Rgb(120, 220, 140))),
                // 30: "oci-analytics-pub  10.1.0.1" is 27 wide and used to
                // run straight into its own latency.
                Span::styled(format!("{name:<30}"), if sel { style.add_modifier(Modifier::BOLD) } else { style }),
                Span::styled(note, Style::default().fg(DIM)),
            ]));
        };
        row(
            0,
            cur.is_none(),
            format!("{}  (this machine)", self.host),
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
            "  ↑↓ pick · enter measures it · esc cancels · the peer needs my-konsole-tray",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(l), inner);
    }

    /// The `x` menu. Each entry says what it actually does, because "clean
    /// memory" means four different things and three of them are myths.
    fn render_free(&self, f: &mut Frame, area: Rect) {
        let accent = Color::Rgb(120, 220, 140);
        let inner = Self::modal(f, area, 86, FREE.len() as u16 * 2 + 4, "free memory", accent);
        let mut l: Vec<Line> = vec![];
        for (i, (_, title, why)) in FREE.iter().enumerate() {
            let sel = i == self.free_sel;
            l.push(Line::from(vec![
                Span::styled(if sel { "▶  " } else { "   " }, Style::default().fg(accent)),
                Span::styled(format!("{}  ", i + 1), Style::default().fg(DIM)),
                Span::styled(
                    title.to_string(),
                    if sel {
                        Style::default().fg(Color::White).add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(Color::Gray)
                    },
                ),
            ]));
            l.push(Line::from(Span::styled(format!("        {why}"), Style::default().fg(DIM))));
        }
        l.push(Line::from(Span::styled(
            "  ↑↓ pick · enter or a digit runs it · any other key cancels",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(l), inner);
    }

    fn render_overlays(&self, f: &mut Frame, area: Rect) {
        match self.overlay {
            Overlay::Kill => self.render_kill(f, area),
            Overlay::Menu => self.render_menu(f, area),
            Overlay::Help => self.render_help(f, area),
            Overlay::Detail => self.render_detail(f, area),
            Overlay::Target => self.render_target(f, area),
            Overlay::Free => self.render_free(f, area),
            Overlay::Unit => self.render_unit(f, area),
            Overlay::Machine => self.render_machine(f, area),
            Overlay::Ctr => self.render_ctr(f, area),
            Overlay::Img => self.render_img(f, area),
            Overlay::None => {}
        }
    }

    /// One machine, whole: what it is, what it is doing, and how much it has
    /// moved since it booted.
    ///
    /// The totals are the daemon's arithmetic, not this panel's — the local
    /// daemon computes them from /proc and the remote collector computes them
    /// the same way, so a peer and this machine answer the question
    /// identically instead of one of them being reconstructed here.
    fn render_machine(&self, f: &mut Frame, area: Rect) {
        let Some(alias) = self.machine.clone() else { return };
        let peers = self.mesh.list();
        let peer = peers.iter().find(|p| p.alias == alias);
        let local = peer.map(|p| p.local).unwrap_or(false);
        let v = if local {
            self.snap.clone()
        } else {
            self.mesh.fleet().get(&alias).and_then(|r| r.clone().ok()).unwrap_or(Value::Null)
        };
        let accent = Color::Rgb(120, 200, 255);
        let inner = Self::modal(f, area, 82, 26, &alias, accent);
        if v.is_null() {
            f.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    format!("  no snapshot from {alias} yet — the sweep runs every 20s"),
                    Style::default().fg(Color::Rgb(240, 160, 90)),
                ))),
                inner,
            );
            return;
        }
        let head = |t: &str| -> Line<'static> {
            Line::from(Span::styled(t.to_string(), Style::default().fg(accent).add_modifier(Modifier::BOLD)))
        };
        let kv = |k: &str, val: String| -> Line<'static> {
            Line::from(vec![
                Span::styled(format!("  {k:<20}"), Style::default().fg(LABEL)),
                Span::styled(val, Style::default().fg(Color::Gray)),
            ])
        };
        let g = |k: &str| num(&v, k);
        let hi = |k: &str| text(&v, &format!("host_info.{k}"));
        let mut l = vec![head("identity")];
        l.push(kv("host", if hi("host").is_empty() { alias.clone() } else { hi("host") }));
        l.push(kv("address", peer.map(|p| p.ip.clone()).unwrap_or_default()));
        if !hi("os").is_empty() {
            l.push(kv("os", hi("os")));
        }
        l.push(kv("kernel", hi("kernel")));
        l.push(kv("uptime", fmt_uptime(num(&v, "totals.since_s"))));
        l.push(kv(
            "reached",
            match peer {
                Some(p) if p.local => "locally — this is the hub".into(),
                Some(p) if p.up => format!("ssh · {:.0} ms", p.rtt_ms),
                _ => "unreachable".into(),
            },
        ));

        l.push(head("now"));
        let ncpu = arr(&v, "cores").len().max(1);
        l.push(kv("cpu", format!("{:.1}%  over {} cores", g("cpu"), ncpu)));
        l.push(kv(
            "load",
            format!("{:.2}  {:.2}  {:.2}", g("load1"), g("load5"), g("load15")),
        ));
        l.push(kv(
            "memory",
            format!("{:.1}%  {} of {}", g("mem"), fmt_gib(num(&v, "mem_detail.used")), fmt_gib(num(&v, "mem_detail.total"))),
        ));
        l.push(kv(
            "swap",
            format!("{:.1}%  {} of {}", g("swap"), fmt_gib(num(&v, "swap_detail.used")), fmt_gib(num(&v, "swap_detail.total"))),
        ));
        l.push(kv(
            "psi cpu / io / mem",
            format!("{:.2}  {:.2}  {:.2}", g("psi.cpu.some10"), g("psi.io.full10"), g("psi.memory.full10")),
        ));
        l.push(kv("processes", format!("{} in the table", arr(&v, "proc_table").len())));

        // ── since boot ─────────────────────────────────────────────────
        l.push(head("moved since boot"));
        let secs = num(&v, "totals.since_s").max(1.0);
        let t = |k: &str| num(&v, &format!("totals.{k}"));
        let per_day = |b: f64| fmt_bytes_short(b / secs * 86400.0);
        l.push(kv(
            "downloaded",
            format!("{}   ({}/day)", fmt_bytes_short(t("net_rx_bytes")), per_day(t("net_rx_bytes"))),
        ));
        l.push(kv(
            "uploaded",
            format!("{}   ({}/day)", fmt_bytes_short(t("net_tx_bytes")), per_day(t("net_tx_bytes"))),
        ));
        l.push(kv(
            "read from disk",
            format!("{}   ({}/day)", fmt_bytes_short(t("disk_read_bytes")), per_day(t("disk_read_bytes"))),
        ));
        l.push(kv(
            "written to disk",
            format!("{}   ({}/day)", fmt_bytes_short(t("disk_write_bytes")), per_day(t("disk_write_bytes"))),
        ));
        l.push(Line::from(Span::styled(
            "  counters are the kernel's own, cumulative since boot — nothing here accumulates them",
            Style::default().fg(DIM),
        )));

        let ifaces = arr(&v, "host_info.ifaces");
        if !ifaces.is_empty() {
            // The mesh interfaces first and in full — v4 AND v6, both of which
            // a peer has — because the mesh address is how this machine is
            // reached and the one people come here for.
            let mesh: Vec<&Value> = ifaces
                .iter()
                .filter(|i| i.get("mesh").and_then(|m| m.as_bool()).unwrap_or(false))
                .collect();
            if !mesh.is_empty() {
                l.push(head("mesh"));
                for i in mesh {
                    let mtu = text(i, "mtu");
                    let st = text(i, "state");
                    l.push(kv(
                        &text(i, "name"),
                        format!(
                            "{}{}{}",
                            text(i, "addr"),
                            if mtu.is_empty() { String::new() } else { format!("   mtu {mtu}") },
                            if st.is_empty() { String::new() } else { format!("   {st}") },
                        ),
                    ));
                }
                l.push(Line::from(Span::styled(
                    "  keys, last handshake and per-peer transfer need root — wg(8) and",
                    Style::default().fg(DIM),
                )));
                l.push(Line::from(Span::styled(
                    "  /etc/wireguard are unreadable to an unprivileged sampler, here and on every peer.",
                    Style::default().fg(DIM),
                )));
            }
            l.push(head("network"));
            // Every remaining interface, not the first six: a box with a dozen
            // docker bridges was silently cutting the one address that mattered.
            for i in ifaces.iter().filter(|i| !i.get("mesh").and_then(|m| m.as_bool()).unwrap_or(false)) {
                l.push(kv(&text(i, "name"), text(i, "addr")));
            }
            let dns: Vec<String> = arr(&v, "host_info.dns")
                .iter()
                .filter_map(|d| d.as_str().map(|x| x.to_string()))
                .collect();
            let pubip = text(&v, "host_info.public");
            l.push(kv("public", if pubip.is_empty() { "behind NAT".into() } else { pubip }));
            l.push(kv("gateway", text(&v, "host_info.gateway")));
            l.push(kv("dns", if dns.is_empty() { "—".into() } else { dns.join("  ") }));
        }
        l.push(Line::from(Span::styled(
            "  ↑↓ scroll · any other key returns",
            Style::default().fg(DIM),
        )));
        let max = (l.len() as u16).saturating_sub(inner.height);
        f.render_widget(Paragraph::new(l).scroll((self.detail_scroll.min(max), 0)), inner);
    }

    /// The container rows in the order the view shows them — ranked and, for
    /// the name column, alphabetical. One function so the renderer and the
    /// cursor agree on which row is which.
    fn ctr_rows<'a>(&self, s: &'a Value) -> Vec<&'a Value> {
        let mut v: Vec<&Value> = arr(s, "containers").iter().collect();
        let (label, field) = CTR_SORT[self.ctr_sort.min(CTR_SORT.len() - 1)];
        v.sort_by(|a, b| {
            let key = |x: &Value| -> f64 {
                // MEM USED is the left of the slash, not the whole cell:
                // ranking on "469.7MiB / 7.595GiB" as one string would rank by
                // whichever container has the biggest LIMIT.
                if field == "mem" { ctr_num(&ctr_mem(&text(x, field)).0) } else { ctr_num(&text(x, field)) }
            };
            let ord = if label == "CONTAINER" {
                text(a, field).to_lowercase().cmp(&text(b, field).to_lowercase())
            } else {
                key(a).partial_cmp(&key(b)).unwrap_or(std::cmp::Ordering::Equal)
            };
            if self.ctr_desc { ord.reverse() } else { ord }
        });
        v
    }

    /// The image rows in the order the view shows them.
    fn img_rows<'a>(&self, s: &'a Value) -> Vec<&'a Value> {
        let mut v: Vec<&Value> = arr(s, "images").iter().collect();
        let (label, field) = IMG_SORT[self.img_sort.min(IMG_SORT.len() - 1)];
        v.sort_by(|a, b| {
            let ord = match label {
                "IMAGE" => text(a, field).to_lowercase().cmp(&text(b, field).to_lowercase()),
                "CREATED" => age_secs(&text(a, field))
                    .partial_cmp(&age_secs(&text(b, field)))
                    .unwrap_or(std::cmp::Ordering::Equal),
                _ => ctr_num(&text(a, field))
                    .partial_cmp(&ctr_num(&text(b, field)))
                    .unwrap_or(std::cmp::Ordering::Equal),
            };
            if self.img_desc { ord.reverse() } else { ord }
        });
        v
    }

    /// One container, whole, with the verbs that act on it.
    fn render_ctr(&self, f: &mut Frame, area: Rect) {
        let s = self.snap.clone();
        let rows = self.ctr_rows(&s);
        let pin = self.ctr_pin.clone().unwrap_or_default();
        let Some(c) = rows.iter().find(|c| text(c, "name") == pin) else { return };
        let accent = Color::Rgb(120, 200, 255);
        let name = text(c, "name");
        let inner = Self::modal(f, area, 92, 24, &name, accent);
        let kv = |k: &str, v: String| -> Line<'static> {
            Line::from(vec![
                Span::styled(format!("  {k:<16}"), Style::default().fg(LABEL)),
                Span::styled(v, Style::default().fg(Color::Gray)),
            ])
        };
        let or = |k: &str| -> String {
            let v = text(c, k);
            // Empty means docker could not read the cgroup, which is not zero.
            if v.is_empty() { "—".into() } else { v }
        };
        let mut l = vec![Line::from(Span::styled(
            "what it is",
            Style::default().fg(accent).add_modifier(Modifier::BOLD),
        ))];
        l.push(kv("image", text(c, "image")));
        l.push(kv("on disk", or("image_size")));
        l.push(kv("state", format!("{}  {}", text(c, "state"), text(c, "status"))));
        l.push(kv("up", or("uptime")));
        l.push(kv("command", or("command")));
        l.push(kv("ports", or("ports")));
        l.push(Line::from(Span::styled(
            "using",
            Style::default().fg(accent).add_modifier(Modifier::BOLD),
        )));
        l.push(kv("cpu", or("cpu")));
        l.push(kv("memory", format!("{}   {}", or("mem"), or("mem_pct"))));
        l.push(kv("net i/o", or("net")));
        l.push(kv("block i/o", or("block")));
        l.push(kv("pids", or("pids")));
        l.push(Line::from(Span::styled(
            "act",
            Style::default().fg(Color::Rgb(240, 169, 66)).add_modifier(Modifier::BOLD),
        )));
        for (i, (verb, why)) in CTR_ACTIONS.iter().enumerate() {
            let sel = i == self.act_sel;
            l.push(Line::from(vec![
                Span::styled(if sel { "▶ " } else { "  " }, Style::default().fg(accent)),
                Span::styled(format!(" {}  ", i + 1), Style::default().fg(DIM)),
                Span::styled(
                    format!("{verb:<10}"),
                    if sel {
                        Style::default().fg(Color::White).add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(Color::Gray)
                    },
                ),
                Span::styled(why.to_string(), Style::default().fg(LABEL)),
            ]));
        }
        l.push(Line::from(Span::styled(
            "  ↑↓ pick · enter or a digit sends it · any other key returns · no remove, on purpose",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(l), inner);
    }

    /// One image, whole, with the verbs that act on it.
    fn render_img(&self, f: &mut Frame, area: Rect) {
        let s = self.snap.clone();
        let imgs = self.img_rows(&s);
        let pin = self.img_pin.clone().unwrap_or_default();
        let Some(i) = imgs
            .iter()
            .find(|i| format!("{}:{}", text(i, "repo"), text(i, "tag")) == pin)
        else {
            return;
        };
        let accent = Color::Rgb(120, 200, 255);
        let full = format!("{}:{}", text(i, "repo"), text(i, "tag"));
        let inner = Self::modal(f, area, 92, 16, &full, accent);
        let kv = |k: &str, v: String| -> Line<'static> {
            Line::from(vec![
                Span::styled(format!("  {k:<16}"), Style::default().fg(LABEL)),
                Span::styled(v, Style::default().fg(Color::Gray)),
            ])
        };
        // Which containers this image is behind. It is the answer to "can I
        // delete this", and docker's own refusal is the other half.
        let users: Vec<String> = arr(&s, "containers")
            .iter()
            .filter(|c| text(c, "image") == full)
            .map(|c| text(c, "name"))
            .collect();
        let mut l = vec![Line::from(Span::styled(
            "image",
            Style::default().fg(accent).add_modifier(Modifier::BOLD),
        ))];
        l.push(kv("repository", text(i, "repo")));
        l.push(kv("tag", text(i, "tag")));
        l.push(kv("id", text(i, "id")));
        l.push(kv("size", text(i, "size")));
        l.push(kv("created", text(i, "created")));
        l.push(kv(
            "used by",
            if users.is_empty() { "nothing — this is dead weight".into() } else { users.join(", ") },
        ));
        l.push(Line::from(Span::styled(
            "act",
            Style::default().fg(Color::Rgb(240, 169, 66)).add_modifier(Modifier::BOLD),
        )));
        for (n, (verb, why)) in IMG_ACTIONS.iter().enumerate() {
            let sel = n == self.act_sel;
            l.push(Line::from(vec![
                Span::styled(if sel { "▶ " } else { "  " }, Style::default().fg(accent)),
                Span::styled(format!(" {}  ", n + 1), Style::default().fg(DIM)),
                Span::styled(
                    format!("{verb:<10}"),
                    if sel {
                        Style::default().fg(Color::White).add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(Color::Gray)
                    },
                ),
                Span::styled(why.to_string(), Style::default().fg(LABEL)),
            ]));
        }
        l.push(Line::from(Span::styled(
            "  ↑↓ pick · enter or a digit sends it · any other key returns",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(l), inner);
    }

    /// Both action modals share their key handling: pick a row, fire a verb on
    /// the mailbox, close. `ctr` picks which table and which verb prefix.
    fn ctr_img_key(&mut self, k: KeyCode, ctr: bool) {
        let n = if ctr { CTR_ACTIONS.len() } else { IMG_ACTIONS.len() };
        let fire = |me: &mut Self, i: usize| {
            let s = me.snap.clone();
            // The pinned one, so an action never lands on a row that moved.
            let target = if ctr { me.ctr_pin.clone() } else { me.img_pin.clone() };
            let _ = &s;
            if let Some(t) = target {
                let verb = if ctr { CTR_ACTIONS[i].0 } else { IMG_ACTIONS[i].0 };
                me.request_docker(if ctr { "CTR" } else { "IMG" }, verb, &t);
            }
            me.overlay = Overlay::None;
        };
        match k {
            KeyCode::Down => self.act_sel = (self.act_sel + 1) % n,
            KeyCode::Up => self.act_sel = (self.act_sel + n - 1) % n,
            KeyCode::Char(c) if c.is_ascii_digit() => {
                let i = c.to_digit(10).unwrap_or(0) as usize;
                if i >= 1 && i <= n {
                    fire(self, i - 1);
                }
            }
            KeyCode::Enter => {
                let i = self.act_sel;
                fire(self, i);
            }
            _ => self.overlay = Overlay::None,
        }
    }

    /// "0 CTR <verb> <name>" / "0 IMG <verb> <ref>" on the same mailbox the
    /// signals use — the daemon allow-lists the verb, the panel decides
    /// nothing.
    fn request_docker(&mut self, kind: &str, verb: &str, target: &str) {
        let path = kill_path();
        let res = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .and_then(|mut f| writeln!(f, "0 {kind} {verb} {target}"));
        self.msg = Some(match res {
            Ok(()) => (format!("{verb} {target} → queued for the daemon"), false),
            Err(e) => (format!("could not write {path}: {e}"), true),
        });
    }

    /// What can be done to a declared unit. Same mailbox as the signals, so
    /// the daemon applies one policy to everything the panel asks for.
    fn render_unit(&self, f: &mut Frame, area: Rect) {
        let Some((name, scope)) = self.acting_unit.clone() else { return };
        let accent = Color::Rgb(240, 169, 66);
        let inner = Self::modal(f, area, 78, UNIT_ACTIONS.len() as u16 + 5, "act on unit", accent);
        let mut l: Vec<Line> = vec![
            Line::from(vec![
                Span::styled(trunc(&name, 46), Style::default().fg(Color::White).add_modifier(Modifier::BOLD)),
                Span::styled(format!("  ({scope} manager)"), Style::default().fg(DIM)),
            ]),
            Line::from(""),
        ];
        for (i, (verb, why)) in UNIT_ACTIONS.iter().enumerate() {
            let sel = i == self.unit_sel;
            l.push(Line::from(vec![
                Span::styled(if sel { "▶ " } else { "  " }, Style::default().fg(accent)),
                Span::styled(format!(" {}  ", i + 1), Style::default().fg(DIM)),
                Span::styled(
                    format!("{verb:<14}"),
                    if sel {
                        Style::default().fg(Color::White).add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(Color::Gray)
                    },
                ),
                Span::styled(why.to_string(), Style::default().fg(LABEL)),
            ]));
        }
        l.push(Line::from(Span::styled(
            "  ↑↓ pick · enter or a digit sends it · any other key cancels",
            Style::default().fg(DIM),
        )));
        f.render_widget(Paragraph::new(l), inner);
    }

    fn unit_key(&mut self, k: KeyCode) {
        let Some((name, scope)) = self.acting_unit.clone() else {
            self.overlay = Overlay::None;
            return;
        };
        let fire = |me: &mut Self, i: usize| {
            me.request_unit(&name, &scope, UNIT_ACTIONS[i].0);
            me.acting_unit = None;
            me.overlay = Overlay::None;
        };
        match k {
            KeyCode::Down => self.unit_sel = (self.unit_sel + 1) % UNIT_ACTIONS.len(),
            KeyCode::Up => self.unit_sel = (self.unit_sel + UNIT_ACTIONS.len() - 1) % UNIT_ACTIONS.len(),
            KeyCode::Char(c) if c.is_ascii_digit() => {
                let i = c.to_digit(10).unwrap_or(0) as usize;
                if i >= 1 && i <= UNIT_ACTIONS.len() {
                    fire(self, i - 1);
                }
            }
            KeyCode::Enter => {
                let i = self.unit_sel;
                fire(self, i);
            }
            _ => {
                self.acting_unit = None;
                self.overlay = Overlay::None;
            }
        }
    }

    /// "0 UNIT <scope> <verb> <name>" on the same mailbox the signals use.
    /// pid 0 because this is addressed to the machine, not to a process.
    fn request_unit(&mut self, name: &str, scope: &str, verb: &str) {
        let path = kill_path();
        let res = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .and_then(|mut f| writeln!(f, "0 UNIT {scope} {verb} {name}"));
        self.msg = Some(match res {
            Ok(()) => (format!("{verb} {name} → queued for the daemon"), false),
            Err(e) => (format!("could not write {path}: {e}"), true),
        });
    }

    /// Write every tab out. Kept in one place so the global key path is the
    /// only thing that has to know how.
    ///
    /// `all` folds every peer into the same file. Off by default: the fleet
    /// was three quarters of the old export, and most exports are about the
    /// machine in front of you.
    fn export_now(&mut self, all: bool) {
        let snap = self.snap.clone();
        let t = self.mesh.target();
        // Peers are collected only when asked for — fleet() is an ssh round
        // trip per peer, so the default export does not pay for it at all.
        let fleet: Vec<(String, Value)> = if all {
            self.mesh
                .fleet()
                .into_iter()
                .filter_map(|(k, v)| v.ok().map(|v| (k, v)))
                .collect()
        } else {
            Vec::new()
        };
        // Exporting without having opened the files tab should still carry the
        // tree rather than an empty list.
        let levels = if self.files_cache.iter().all(|v| v.is_empty()) {
            file_tree(self.files_hidden)
        } else {
            self.files_cache.clone()
        };
        // L3 only. The four panes overlap by construction — every L4 path has
        // its L3 parent above it and its L1 grandparent above that — so
        // concatenating them wrote the same prefixes four times over. L3 is
        // the level that carries the shape of the tree without the leaf spray
        // of L4, and one pane is the whole of it.
        let files: Vec<String> = levels[2].clone();
        self.msg = Some(match export_snapshot(&snap, t, &files, &fleet) {
            Ok(stem) => {
                let what = if all { format!(" + {} peers", fleet.len()) } else { String::new() };
                (format!("exported {stem}.json .yaml .md{what}"), false)
            }
            Err(e) => (format!("export failed: {e}"), true),
        });
    }

    /// The tab keys, honoured from whichever view you are in.
    ///
    /// They were handled per-view, so pressing `z` while looking at containers
    /// did nothing at all — a tab strip that only works from one tab is not a
    /// tab strip. Returns true when the key was a tab switch.
    fn view_key(&mut self, k: KeyCode) -> bool {
        let KeyCode::Char(c) = k else { return false };
        // Export is a GLOBAL action and must be handled before the per-view
        // branches, not inside the process view's match. It was reachable only
        // from the process list and silently did nothing everywhere else —
        // the same failure as a key the frame had already taken.
        if c == 'E' || c == 'A' {
            self.export_now(c == 'A');
            return true;
        }
        let _ = ();
        let flat = !self.tree
            && !self.zombies
            && !self.docker
            && !self.images
            && !self.files
            && !self.fleet
            && !self.history
            && !self.about;
        if !matches!(c, 'p' | 't' | 'z' | 'o' | 'I' | 'f' | 'y' | 'F' | 'b') {
            return false;
        }
        // A view is a single choice, so every switch clears the others rather
        // than leaving two flags true and the tab strip disagreeing with the
        // body.
        let was_fleet = self.fleet;
        self.tree = false;
        self.zombies = false;
        self.docker = false;
        self.images = false;
        self.files = false;
        self.fleet = false;
        self.history = false;
        self.about = false;
        let name = match c {
            't' => {
                self.tree = true;
                "process tree"
            }
            'z' => {
                self.zombies = true;
                "zombies and orphans — dead, or reparented to init"
            }
            'o' => {
                self.docker = true;
                self.sel = 0;
                "containers"
            }
            'I' => {
                self.images = true;
                self.sel = 0;
                "images — running or not"
            }
            'f' => {
                self.fleet = true;
                "fleet — every mesh peer, collected over ssh"
            }
            'y' => {
                self.history = true;
                "the last 24 hours"
            }
            'F' => {
                self.files = true;
                self.files_scroll = 0;
                self.files_cache = file_tree(self.files_hidden);
                "home, four levels deep"
            }
            'b' => {
                self.about = true;
                "about this machine"
            }
            _ => "process list",
        };
        if was_fleet != self.fleet {
            self.mesh.set_fleet(self.fleet);
            self.sel = 0;
        }
        self.msg = Some((name.to_string(), false));
        true
    }

    fn free_key(&mut self, k: KeyCode) {
        let run = |me: &mut Self, i: usize| {
            match FREE[i].0 {
                // pid 0: these are addressed to the machine, not a process.
                // The daemon answers them before its per-pid guards.
                "REAP" => me.request_kill(0, "REAP"),
                "RECLAIM" => me.request_kill(0, "RECLAIM"),
                _ => {
                    me.orphans = !me.orphans;
                    me.msg = Some((
                        if me.orphans {
                            "showing orphans only — reparented to init, under no unit. k to act.".into()
                        } else {
                            "showing every process again".to_string()
                        },
                        false,
                    ));
                }
            }
            me.overlay = Overlay::None;
        };
        match k {
            KeyCode::Down => self.free_sel = (self.free_sel + 1) % FREE.len(),
            KeyCode::Up => self.free_sel = (self.free_sel + FREE.len() - 1) % FREE.len(),
            KeyCode::Char(c) if c.is_ascii_digit() => {
                let i = c.to_digit(10).unwrap_or(0) as usize;
                if i >= 1 && i <= FREE.len() {
                    run(self, i - 1);
                }
            }
            KeyCode::Enter => {
                let i = self.free_sel;
                run(self, i);
            }
            _ => self.overlay = Overlay::None,
        }
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
        let mut l: Vec<Line> = vec![];

        // Rendered FROM the tables the handler dispatches from, never written
        // out a second time beside them. Two lists of keybindings is how a key
        // ends up documented and unhandled — or, as "about a" was, listed in
        // two places and eaten by the frame before either could act on it.
        let section = |l: &mut Vec<Line>, name: &str| {
            l.push(head(name));
            for (sec, k, d) in OTHER_KEYS.iter().filter(|(s, _, _)| *s == name) {
                let _ = sec;
                l.push(key(k, d));
            }
        };

        section(&mut l, "moving");

        l.push(head("tabs"));
        for (name, k) in VIEW_TABS {
            l.push(key(
                &k.to_string(),
                &format!(
                    "{name}{}",
                    match *name {
                        "proc" => " — the flat process list",
                        "tree" => " — parents, children, zombies",
                        "zombies" => " — only the ones nothing owns",
                        "containers-c" => " — running containers, enter for detail and actions",
                    "containers-i" => " — every image on the box, enter for detail and actions",
                        "fleet" => " — every mesh peer's totals side by side",
                        "history" => " — what this machine did over the last day",
                        "files" => " — home as four panes, one per level, . toggles dotfiles",
                    "about" => " — what this machine is, not what it is doing",
                        _ => "",
                    }
                ),
            ));
        }
        l.push(key("v", "add the declared units that are stopped or idle"));

        l.push(head("sorting"));
        // One line per group of four so nine sort keys do not take nine rows.
        for chunk in SORT_KEYS.chunks(4) {
            let ks: Vec<String> = chunk.iter().map(|(k, _, _)| k.to_string()).collect();
            let ds: Vec<&str> = chunk.iter().map(|(_, _, d)| *d).collect();
            l.push(key(&ks.join(" "), &format!("sort by {}", ds.join(" · "))));
        }
        for (sec, k, d) in OTHER_KEYS.iter().filter(|(s, _, _)| *s == "sorting") {
            let _ = sec;
            l.push(key(k, d));
        }

        section(&mut l, "acting");
        section(&mut l, "modal");

        l.push(head("layout"));
        for (i, b) in BOX_NAMES.iter().enumerate() {
            l.push(key(
                &format!("{}", i + 1),
                &format!("show/hide the {b} box ({})", if self.show[i] { "shown" } else { "hidden" }),
            ));
        }

        section(&mut l, "leaving");
        l.push(Line::from(Span::styled("  any key returns", Style::default().fg(DIM))));
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
        // The pinned pid, looked up in the current table so the live figures
        // stay live. If it has left the table, /proc may still have it, so the
        // modal keeps describing it rather than jumping to whoever took its
        // place in the ranking.
        let Some(pid) = self.detail_pid else { return };
        let rows = self.rows();
        let row = rows.iter().find(|p| num(p, "pid") as i32 == pid);
        let name = row
            .map(|p| text(p, "name"))
            .unwrap_or_else(|| proc_comm(pid).unwrap_or_else(|| "(gone)".into()));
        let prot = row
            .map(|p| p.get("protected").and_then(|v| v.as_bool()).unwrap_or(false))
            .unwrap_or(false);
        let why = row.map(|p| text(p, "protected_reason")).unwrap_or_default();
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
        let p = row.map(|p| (*p).clone()).unwrap_or(Value::Null);

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
        // smaps_rollup, read here rather than taken from the snapshot: this is
        // one process, the modal is already reading /proc for this pid, and it
        // carries USS which the table has no column for. The three figures
        // answer three different questions and only together are they honest:
        //   RSS  every resident page, shared ones counted in full — the number
        //        that sums to far more than the RAM installed
        //   PSS  private pages plus this process's SHARE of each shared one —
        //        the number that sums to the truth across the whole box
        //   USS  private pages only — what you would actually get back by
        //        killing it, which is usually the question being asked
        let roll = rd("smaps_rollup");
        let rk = |k: &str| -> Option<f64> {
            roll.lines()
                .find(|l| l.starts_with(&format!("{k}:")))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|v| v.parse::<f64>().ok())
                .map(|kb| kb * 1024.0)
        };
        let uss = match (rk("Private_Clean"), rk("Private_Dirty")) {
            (Some(c), Some(d)) => Some(c + d),
            (a, b) => a.or(b),
        };
        let one = |v: Option<f64>| v.map(fmt_bytes_short).unwrap_or_else(|| "—".into());
        l.push(kv(
            "rss / pss / uss",
            format!("{}  {}  {}", one(rk("Rss")), one(rk("Pss")), one(uss)),
        ));
        l.push(kv(
            "  what each means",
            "rss all resident · pss share-adjusted · uss private only".into(),
        ));
        if roll.is_empty() {
            l.push(kv("  smaps_rollup", "not readable for this uid".into()));
        }
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
        l.push(kv(
            "down / up",
            format!(
                "{}  {}",
                fmt_bps(num(&p, "net_rx_bytes_per_s")),
                fmt_bps(num(&p, "net_tx_bytes_per_s"))
            ),
        ));
        // Everything this process has moved, not the rate it is moving at.
        // Disk comes straight from /proc/PID/io, which is cumulative for the
        // life of the process. Network is integrated by the daemon: the
        // kernel keeps no per-process network counter, so a total can only be
        // built by summing what it sees, which means traffic on a socket
        // opened and closed between two samples is missed. It undercounts and
        // never overcounts — the right way round for a number read as a total.
        l.push(kv(
            "downloaded (total)",
            fmt_bytes_short(num(&p, "net_rx_bytes_total")),
        ));
        l.push(kv("uploaded (total)", fmt_bytes_short(num(&p, "net_tx_bytes_total"))));
        l.push(kv("read (total)", fmt_bytes_short(num(&p, "read_bytes_total"))));
        l.push(kv("written (total)", fmt_bytes_short(num(&p, "write_bytes_total"))));
        l.push(Line::from(Span::styled(
            "  disk totals are the process's own since it started; network is the daemon's running sum",
            Style::default().fg(DIM),
        )));
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
    /// Reparented to init and under no systemd unit: a process whose parent
    /// died and which nothing is supervising. That is a much narrower claim
    /// than "lost" — a daemon legitimately parented to pid 1 sits inside its
    /// own .service cgroup and is excluded — and it is the set actually worth
    /// looking at when memory has gone somewhere nobody owns.
    fn is_orphan(p: &Value) -> bool {
        num(p, "ppid") as i64 == 1
    }

    /// Nothing is looking after this one: it is either already dead and
    /// uncollected, or its parent died and init inherited it.
    fn is_lost(p: &Value) -> bool {
        text(p, "state").starts_with('Z') || Self::is_orphan(p)
    }

    fn rows(&self) -> Vec<&Value> {
        let procs = sort_procs(&self.snap, self.sort, self.desc, self.win);
        let procs: Vec<&Value> = if self.orphans || self.zombies {
            procs.into_iter().filter(|p| Self::is_lost(p)).collect()
        } else {
            procs
        };
        if self.tree {
            tree_order(&procs, arr(&self.snap, "proc_spine")).into_iter().map(|(p, _)| p).collect()
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
    fn unit_rows(&self, s: &Value) -> Vec<UnitRow> {
        if !self.units {
            return vec![];
        }
        let live: std::collections::HashSet<String> =
            arr(s, "proc_table").iter().map(|p| text(p, "name")).collect();
        let mut rows: Vec<(String, String, String)> = arr(s, "services")
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
            .collect::<Vec<_>>();

        // Worst first. In systemctl's own order these come out grouped by
        // manager and then alphabetically, which buries the one row anybody
        // opened this list for ("plasmashell is dead, where is it?") a
        // hundred lines down among units that are dead because they are
        // oneshots that already ran.
        let rank = |state: &str| -> u8 {
            if state.starts_with("failed") {
                0
            } else if state.starts_with("inactive") {
                1
            } else if state.starts_with("not-loaded") {
                2
            } else if state.starts_with("active/exited") {
                3
            } else {
                4
            }
        };
        rows.sort_by(|a, b| rank(&a.2).cmp(&rank(&b.2)).then_with(|| a.0.cmp(&b.0)));

        // A heading before each group. Sorted-but-unbroken, the eye cannot
        // tell where "failed" stops and "merely exited" starts, and those two
        // mean completely different things.
        let head_for = |state: &str| -> &'static str {
            match rank(state) {
                0 => "FAILED — died and did not come back",
                1 => "INACTIVE — declared, not running",
                2 => "NOT LOADED — declared, never started this boot",
                3 => "EXITED — oneshots that already ran",
                _ => "IDLE — running, doing nothing",
            }
        };
        let mut out: Vec<UnitRow> = Vec::new();
        let mut last = usize::MAX;
        for (name, scope, state) in rows {
            let r = rank(&state) as usize;
            if r != last {
                last = r;
                out.push(UnitRow { heading: Some(head_for(&state)), name: String::new(), scope: String::new(), state: String::new() });
            }
            out.push(UnitRow { heading: None, name, scope, state });
        }
        out
    }

    /// None when the cursor is parked on an appended unit row: those have no
    /// pid, so every action keyed off a pid correctly does nothing.
    /// The declared unit under the cursor, if the cursor is past the live
    /// processes and not on a group heading.
    fn picked_unit(&self) -> Option<(String, String)> {
        let snap = self.snap.clone();
        let n = self.rows().len();
        let units = self.unit_rows(&snap);
        let u = units.get(self.sel.checked_sub(n)?)?;
        if u.heading.is_some() {
            return None;
        }
        Some((u.name.clone(), u.scope.clone()))
    }

    /// The process the detail modal is pinned to, in the same shape picked()
    /// returns — so acting from inside the modal acts on what is on screen,
    /// not on whatever the cursor has drifted onto behind it.
    fn pinned(&self) -> Option<(i32, String, bool, String)> {
        let pid = self.detail_pid?;
        let rows = self.rows();
        let p = rows.iter().find(|p| num(p, "pid") as i32 == pid)?;
        Some((
            pid,
            text(p, "name"),
            p.get("protected").and_then(|v| v.as_bool()).unwrap_or(false),
            text(p, "protected_reason"),
        ))
    }

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
        // rows(), not proc_table: in tree mode the list also carries the
        // spine, so counting the published rows capped the cursor above the
        // real end of the list and scrolling simply stopped.
        let n = self.rows().len() + self.unit_rows(&snap).len();
        match self.overlay {
            Overlay::Kill => return self.kill_key(k),
            Overlay::Free => return self.free_key(k),
            Overlay::Ctr => return self.ctr_img_key(k, true),
            Overlay::Img => return self.ctr_img_key(k, false),
            Overlay::Unit => return self.unit_key(k),
            Overlay::Machine => {
                match k {
                    KeyCode::Down | KeyCode::Char('j') => self.detail_scroll = self.detail_scroll.saturating_add(1),
                    KeyCode::Up => self.detail_scroll = self.detail_scroll.saturating_sub(1),
                    KeyCode::Home => self.detail_scroll = 0,
                    _ => {
                        self.machine = None;
                        self.overlay = Overlay::None;
                    }
                }
                return;
            }
            Overlay::Menu => return self.menu_key(k),
            Overlay::Help => {
                // Any key dismisses a page of text; making people find the one
                // right key to leave a help screen is its own small insult.
                self.overlay = Overlay::None;
                return;
            }
            Overlay::Target => {
                let n = Self::selectable_peers(&self.mesh).len() + 1;
                match k {
                    KeyCode::Down => self.target_sel = (self.target_sel + 1) % n,
                    KeyCode::Up => self.target_sel = (self.target_sel + n - 1) % n,
                    KeyCode::Enter | KeyCode::Char(' ') => {
                        let peers = Self::selectable_peers(&self.mesh);
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
                        if let Some((pid, name, prot, why)) = self.pinned() {
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
                        if let Some(pid) = self.detail_pid {
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
        if self.view_key(k) {
            return;
        }
        if self.files {
            match k {
                KeyCode::Down | KeyCode::Char('j') => {
                    self.files_scroll = self.files_scroll.saturating_add(1)
                }
                KeyCode::Up => self.files_scroll = self.files_scroll.saturating_sub(1),
                KeyCode::PageDown => self.files_scroll = self.files_scroll.saturating_add(20),
                KeyCode::PageUp => self.files_scroll = self.files_scroll.saturating_sub(20),
                KeyCode::Home => self.files_scroll = 0,
                KeyCode::Char('.') => {
                    self.files_hidden = !self.files_hidden;
                    self.files_cache = file_tree(self.files_hidden);
                    self.files_scroll = 0;
                    self.msg = Some((
                        format!("dotfiles {}", if self.files_hidden { "shown" } else { "hidden" }),
                        false,
                    ));
                }
                KeyCode::Char('h') | KeyCode::Char('?') | KeyCode::F(1) => self.overlay = Overlay::Help,
                KeyCode::Esc => {
                    self.overlay = Overlay::Menu;
                    self.menu_sel = 0;
                }
                _ => {}
            }
            return;
        }
        if self.history || self.about {
            // None of these has a row cursor; about scrolls, the rest are one
            // screen.
            match k {
                KeyCode::Down | KeyCode::Char('j') => {
                    self.detail_scroll = self.detail_scroll.saturating_add(1)
                }
                KeyCode::Up => self.detail_scroll = self.detail_scroll.saturating_sub(1),
                KeyCode::Home => self.detail_scroll = 0,
                KeyCode::Char('h') | KeyCode::Char('?') | KeyCode::F(1) => self.overlay = Overlay::Help,
                KeyCode::Esc => {
                    self.overlay = Overlay::Menu;
                    self.menu_sel = 0;
                }
                _ => {}
            }
            return;
        }
        if self.docker || self.images {
            // Two lists, one cursor. Without arrow keys a tab showing 52
            // containers can only ever display the first screenful, which is
            // what oci-apps looks like.
            let n = if self.docker {
                arr(&self.snap, "containers").len()
            } else {
                arr(&self.snap, "images").len()
            };
            match k {
                KeyCode::Down | KeyCode::Char('j') => self.sel = (self.sel + 1).min(n.saturating_sub(1)),
                KeyCode::Up => self.sel = self.sel.saturating_sub(1),
                KeyCode::PageDown => self.sel = (self.sel + 10).min(n.saturating_sub(1)),
                KeyCode::PageUp => self.sel = self.sel.saturating_sub(10),
                KeyCode::Home => self.sel = 0,
                KeyCode::End => self.sel = n.saturating_sub(1),
                // Same gesture as the process header: ←/→ walks the column
                // this list is ranked by.
                KeyCode::Left => {
                    if self.docker {
                        self.ctr_sort = (self.ctr_sort + CTR_SORT.len() - 1) % CTR_SORT.len();
                    } else {
                        self.img_sort = (self.img_sort + IMG_SORT.len() - 1) % IMG_SORT.len();
                    }
                }
                KeyCode::Right => {
                    if self.docker {
                        self.ctr_sort = (self.ctr_sort + 1) % CTR_SORT.len();
                    } else {
                        self.img_sort = (self.img_sort + 1) % IMG_SORT.len();
                    }
                }
                KeyCode::Char('i') => {
                    if self.docker {
                        self.ctr_desc = !self.ctr_desc;
                    } else {
                        self.img_desc = !self.img_desc;
                    }
                }
                KeyCode::Enter => {
                    if n > 0 {
                        // Pin by identity, not by row. Re-ranking on the next
                        // tick would otherwise slide a different container
                        // under the modal a second after it opened.
                        let snap = self.snap.clone();
                        if self.docker {
                            self.ctr_pin =
                                self.ctr_rows(&snap).get(self.sel).map(|c| text(c, "name"));
                            self.overlay = Overlay::Ctr;
                        } else {
                            self.img_pin = self.img_rows(&snap).get(self.sel).map(|i| {
                                format!("{}:{}", text(i, "repo"), text(i, "tag"))
                            });
                            self.overlay = Overlay::Img;
                        }
                        self.act_sel = 0;
                        self.detail_scroll = 0;
                    }
                }
                KeyCode::Char('h') | KeyCode::Char('?') | KeyCode::F(1) => self.overlay = Overlay::Help,
                KeyCode::Esc => {
                    self.overlay = Overlay::Menu;
                    self.menu_sel = 0;
                }
                _ => {}
            }
            return;
        }
        if self.fleet {
            // The fleet table is its own list; the process keys would move a
            // cursor through rows that are not on screen.
            let np = self.mesh.list().len();
            match k {
                KeyCode::Down => self.sel = (self.sel + 1).min(np.saturating_sub(1)),
                KeyCode::Up => self.sel = self.sel.saturating_sub(1),
                KeyCode::Home => self.sel = 0,
                KeyCode::End => self.sel = np.saturating_sub(1),
                KeyCode::Enter => {
                    if let Some(p) = self.mesh.list().get(self.sel) {
                        self.machine = Some(p.alias.clone());
                        self.detail_scroll = 0;
                        self.overlay = Overlay::Machine;
                    }
                }
                KeyCode::Char('h') | KeyCode::Char('?') | KeyCode::F(1) => self.overlay = Overlay::Help,
                KeyCode::Esc => {
                    self.overlay = Overlay::Menu;
                    self.menu_sel = 0;
                }
                _ => {}
            }
            return;
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
            // From SORT_KEYS, not from nine hand-written arms: the help
            // renders from the same table, so the two cannot disagree.
            KeyCode::Char(c) if SORT_KEYS.iter().any(|(k, _, _)| *k == c) => {
                self.sort = SORT_KEYS.iter().find(|(k, _, _)| *k == c).map(|(_, s, _)| *s).unwrap();
            }
            KeyCode::Char('s') => self.sort = Sort::Slice,
            KeyCode::Char('i') => self.desc = !self.desc,
            KeyCode::Char('w') => self.win = self.win.next(),
            KeyCode::Char('x') => {
                self.free_sel = 0;
                self.overlay = Overlay::Free;
            }
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
                if let Some((pid, _, _, _)) = self.picked() {
                    // Pin it. Without this the modal followed the cursor's ROW
                    // through every re-sort, so the process being described
                    // changed underneath the reader a second after they opened
                    // it.
                    self.detail_pid = Some(pid);
                    self.detail_scroll = 0;
                    self.overlay = Overlay::Detail;
                } else if let Some(u) = self.picked_unit() {
                    // The cursor is on a declared unit, which has no pid and
                    // so no process detail to show. What it does have is a
                    // systemd verb.
                    self.acting_unit = Some(u);
                    self.unit_sel = 0;
                    self.overlay = Overlay::Unit;
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
        // Identity comes from the SNAPSHOT, not from this machine's /proc: the
        // panel can be pointed at a peer, and a header naming the desktop above
        // another box's numbers is worse than no header at all.
        let hi = |k: &str| text(&s, &format!("host_info.{k}"));
        let host = if hi("host").is_empty() { self.host.clone() } else { hi("host") };
        let kernel = if hi("kernel").is_empty() { self.kernel.clone() } else { hi("kernel") };
        let ifaces = arr(&s, "host_info.ifaces");
        let addr_of = |pred: &dyn Fn(&str) -> bool| -> String {
            ifaces
                .iter()
                .find(|i| pred(&text(i, "name")))
                .map(|i| text(i, "addr").split('/').next().unwrap_or("").to_string())
                .unwrap_or_default()
        };
        let lan = addr_of(&|n: &str| {
            !n.starts_with("wg") && !n.starts_with("docker") && !n.starts_with("br-")
        });
        let wg = addr_of(&|n: &str| n.starts_with("wg"));
        // user@host(ip) — how a machine gets written down. The mesh address is
        // the identifying one: it is what the fleet is addressed by and every
        // peer has exactly one.
        let who = hi("user");
        let ip = if wg.is_empty() { lan.clone() } else { wg };
        let ident = format!(
            "{}{host}{}",
            if who.is_empty() { String::new() } else { format!("{who}@") },
            if ip.is_empty() { String::new() } else { format!(" ({ip})") },
        );
        let mut head = vec![Span::styled(
            format!(" {ident} "),
            Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
        )];
        if let Some(alias) = self.mesh.target() {
            // Never let a remote reading be mistaken for the local one.
            head.push(Span::styled(
                format!("via ssh {alias} "),
                Style::default().fg(Color::Rgb(240, 169, 66)).add_modifier(Modifier::BOLD),
            ));
        }
        if !hi("os").is_empty() {
            head.push(Span::styled(format!("· {} ", hi("os")), Style::default().fg(Color::Gray)));
        }
        head.push(Span::styled(
            format!("· {kernel} · up {} ", fmt_uptime(uptime)),
            Style::default().fg(LABEL),
        ));
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
        // btop's cpu box is not just a graph: it names the chip, and shows
        // what it is clocked at and how hot it is right now. Those three are
        // what makes it read as a CPU box rather than a generic meter.
        let model = text(&s, "cpu_info.model");
        let mhz = num_opt(&s, "cpu_info.mhz");
        let temp = num_opt(&s, "cpu_info.temp_c");
        // btop names the chip on the TOP border, right beside the box name,
        // not tucked into the bottom-right where the key hints go. Trimmed of
        // the marketing: "11th Gen Intel(R) Core(TM) i5-1145G7 @ 2.60GHz" is
        // the same chip as "i5-1145G7" and the rest is border it has to fit in.
        let mut title = "cpu".to_string();
        let short = model
            .replace("(R)", "")
            .replace("(TM)", "")
            .split_whitespace()
            .filter(|w| !w.ends_with("Gen") && *w != "11th" && *w != "Intel" && *w != "Core")
            .collect::<Vec<_>>()
            .join(" ");
        if !short.is_empty() {
            title.push_str(&format!("  {}", trunc(short.trim(), 40)));
        }
        if let Some(m) = mhz {
            title.push_str(&format!("  {:.2}GHz", m / 1000.0));
        }
        if let Some(t) = temp {
            title.push_str(&format!("  {t:.0}°C"));
        }
        let core_temps = arr(&s, "cpu_info.core_temps");
        let cpu_b = bbox(&title, "");
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
        let mw = (cpu_left[1].width as usize).saturating_sub(14);
        let mut total = vec![Span::styled("CPU ", Style::default().fg(Color::Rgb(120, 200, 255)))];
        total.extend(meter(mw, cpu_pct / 100.0, &format!("{cpu_pct:5.1}%")).spans);
        f.render_widget(Paragraph::new(Line::from(total)), cpu_left[1]);

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
                    // btop's core labels are C0, C1, … and each carries its own
                    // temperature. A bare number reads as a row index.
                    let ct = core_temps.get(i).and_then(|v| v.as_f64());
                    let tw = if ct.is_some() { 5 } else { 0 };
                    let bw = (ca.width as usize).saturating_sub(gw + 10 + tw);
                    let mut sp = vec![Span::styled(format!("C{i:<2}"), Style::default().fg(LABEL))];
                    if let Some(h) = self.core_hist.get(i) {
                        sp.extend(braille_graph(h, 100.0, gw, 1).pop().map(|l| l.spans).unwrap_or_default());
                    } else {
                        sp.push(Span::raw(" ".repeat(gw)));
                    }
                    sp.push(Span::raw(" "));
                    sp.extend(meter(bw, v / 100.0, "").spans);
                    sp.push(Span::styled(format!(" {v:>3.0}%"), Style::default().fg(grad(v / 100.0))));
                    if let Some(t) = ct {
                        // Scaled to 100°C: thermal throttling starts around
                        // there, so the colour means "close to throttling"
                        // rather than "warmer than the other cores".
                        sp.push(Span::styled(format!(" {t:>3.0}°"), Style::default().fg(grad(t / 100.0))));
                    }
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

        // GPU memory, and the two kinds are not interchangeable. Dedicated
        // belongs to the card and filling it makes the GPU evict; shared comes
        // out of the same RAM as everything else, so filling it is a memory
        // problem rather than a GPU one. A single merged "VRAM" answers
        // neither question, which is why they are separate rows.
        let vd = |k: &str| -> Option<(f64, f64)> {
            let u = num_opt(&s, &format!("vram_detail.{k}.used"))?;
            let t = num_opt(&s, &format!("vram_detail.{k}.total"))?;
            if t > 0.0 { Some((u, t)) } else { None }
        };
        let ded = vd("dedicated");
        let shr = vd("shared");
        if ded.is_some() || shr.is_some() {
            ml.push(Line::from(Span::styled(
                "VRAM",
                Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
            )));
            if let Some((u, t)) = ded {
                ml.push(bar(
                    "dedicated",
                    u / t * 100.0,
                    format!("{} / {}", fmt_bytes_short(u), fmt_bytes_short(t)),
                ));
            }
            if let Some((u, t)) = shr {
                ml.push(bar(
                    "shared",
                    u / t * 100.0,
                    format!("{} / {}", fmt_bytes_short(u), fmt_bytes_short(t)),
                ));
            }
        }

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
            // The throughput graphs answer "how much"; the config block below
            // answers "where" — which address to reach this box on, through
            // which gateway, resolved by whom. On a remote target it is that
            // machine's configuration, not this one's.
            let cfg = arr(&s, "host_info.ifaces");
            let dns = arr(&s, "host_info.dns");
            // Every interface, plus a gateway line and a DNS line. Capped only
            // by the box: "all the network config" is the point, and hiding
            // the third wg address to save a row defeats it.
            let cfg_h = (cfg.len() + 3).min(net_in.height.saturating_sub(6) as usize).max(3) as u16;
            let nrows = Layout::vertical([
                Constraint::Length(1),
                Constraint::Min(2),
                Constraint::Length(1),
                Constraint::Min(2),
                Constraint::Length(cfg_h),
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

            let mut cl: Vec<Line> = vec![];
            for i in cfg.iter().take(cfg_h.saturating_sub(3) as usize) {
                let n = text(i, "name");
                cl.push(Line::from(vec![
                    Span::styled(
                        format!("{:<10}", trunc(&n, 10)),
                        // The mesh interfaces are the ones that matter here.
                        Style::default().fg(if n.starts_with("wg") {
                            Color::Rgb(120, 200, 255)
                        } else {
                            LABEL
                        }),
                    ),
                    Span::styled(text(i, "addr"), Style::default().fg(Color::Gray)),
                ]));
            }
            let gw = text(&s, "host_info.gateway");
            let ns: Vec<String> = dns.iter().map(|d| d.as_str().unwrap_or("").to_string()).collect();
            let pubip = text(&s, "host_info.public");
            cl.push(Line::from(vec![
                Span::styled(format!("{:<10}", "public"), Style::default().fg(LABEL)),
                Span::styled(
                    if pubip.is_empty() {
                        // Not a failure: from behind NAT it cannot be known
                        // without asking somebody outside.
                        "behind NAT — no routable address on any interface".to_string()
                    } else {
                        pubip.clone()
                    },
                    Style::default().fg(if pubip.is_empty() { DIM } else { Color::Rgb(240, 169, 66) }),
                ),
            ]));
            cl.push(Line::from(vec![
                Span::styled(format!("{:<10}", "gateway"), Style::default().fg(LABEL)),
                Span::styled(
                    format!("{} via {}", if gw.is_empty() { "—" } else { &gw }, text(&s, "host_info.wan_if")),
                    Style::default().fg(Color::Gray),
                ),
            ]));
            let search = arr(&s, "host_info.search");
            cl.push(Line::from(vec![
                Span::styled(format!("{:<10}", "dns"), Style::default().fg(LABEL)),
                Span::styled(
                    if ns.is_empty() { "—".to_string() } else { ns.join("  ") },
                    Style::default().fg(Color::Gray),
                ),
                Span::styled(
                    if search.is_empty() {
                        String::new()
                    } else {
                        format!(
                            "  search {}",
                            search.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(" ")
                        )
                    },
                    Style::default().fg(DIM),
                ),
            ]));
            f.render_widget(Paragraph::new(cl), nrows[4]);
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
                Span::styled("         10s    60s   300s  now", Style::default().fg(LABEL)),
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
                        // 5, not 4: a value of 10 or more fills all five of
                        // its own columns and "some16.75" has no gap at all.
                        Span::styled(format!("{:<5}", band), Style::default().fg(LABEL)),
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
                    let tw = (psi_in.width as usize).saturating_sub(28).min(18);
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
                let here = p.local && target.is_none()
                    || target.as_deref() == Some(p.alias.as_str());
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
                        if p.local {
                            format!("{:>8}", "here")
                        } else if !p.probed {
                            format!("{:>8}", "…")
                        } else if p.up {
                            format!("{:>7.0}ms", p.rtt_ms)
                        } else {
                            format!("{:>8}", "down")
                        },
                        Style::default().fg(if p.local {
                            Color::Rgb(120, 200, 255)
                        } else if p.up {
                            grad(p.rtt_ms / 200.0)
                        } else {
                            DIM
                        }),
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

        // ── files ─────────────────────────────────────────────────────────────
        // The home directory, four levels deep. Cached, because tree(1) walks
        // tens of thousands of inodes and this panel redraws every second.
        if self.files {
            let fb = tabbox(
                VIEW_TABS,
                tab("files"),
                &format!(
                    "four levels side by side · dotfiles {} · . toggles · ↑↓ pgup pgdn",
                    if self.files_hidden { "shown" } else { "hidden" }
                ),
            );
            let fin = fb.inner(rows[4]);
            f.render_widget(fb, rows[4]);
            // One pane per depth, side by side. Four nested trees would be
            // four copies of each other — a level is only interesting next to
            // the other levels, which is what the columns are for.
            let panes = Layout::horizontal([Constraint::Ratio(1, 4); 4]).split(fin);
            for (n, area) in panes.iter().enumerate() {
                let entries = &self.files_cache[n];
                let w = area.width as usize;
                let mut l: Vec<Line> = vec![Line::from(Span::styled(
                    format!("L{}  {} dirs", n + 1, entries.len()),
                    Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
                ))];
                for e in entries.iter().skip(self.files_scroll as usize) {
                    // Elide from the LEFT: the tail is what identifies a path,
                    // and a column this narrow cannot hold "a/b/c/d" whole.
                    let shown = if e.chars().count() > w.saturating_sub(1) {
                        let keep = w.saturating_sub(2);
                        let tail: String = e.chars().rev().take(keep).collect::<Vec<_>>()
                            .into_iter().rev().collect();
                        format!("…{tail}")
                    } else {
                        e.clone()
                    };
                    l.push(Line::from(Span::styled(shown, Style::default().fg(Color::Gray))));
                }
                f.render_widget(Paragraph::new(l), *area);
            }
            let status = Line::from(Span::styled(
                match &self.msg {
                    Some((m, _)) => format!(" {m}"),
                    None => format!(
                        " {} directories · L1 {} · L2 {} · L3 {} · L4 {} · this machine's home, not the peer's",
                        self.files_cache.iter().map(|v| v.len()).sum::<usize>(),
                        self.files_cache[0].len(),
                        self.files_cache[1].len(),
                        self.files_cache[2].len(),
                        self.files_cache[3].len(),
                    ),
                },
                Style::default().fg(LABEL),
            ));
            f.render_widget(Paragraph::new(status), rows[5]);
            self.render_overlays(f, area);
            return;
        }

        // ── about ─────────────────────────────────────────────────────────────
        // What this machine IS, rather than what it is doing. Everything here
        // changes on the scale of a reboot or a reinstall, which is exactly
        // why it does not belong in a box that redraws every second.
        if self.about {
            let ab = tabbox(VIEW_TABS, tab("about"), "b back to processes");
            let ain = ab.inner(rows[4]);
            f.render_widget(ab, rows[4]);
            let hi2 = |k: &str| text(&s, &format!("host_info.{k}"));
            let sect = |t: &str| -> Line<'static> {
                Line::from(Span::styled(
                    t.to_string(),
                    Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
                ))
            };
            let kv2 = |k: &str, v: String| -> Line<'static> {
                Line::from(vec![
                    Span::styled(format!("  {k:<18}"), Style::default().fg(LABEL)),
                    Span::styled(v, Style::default().fg(Color::Gray)),
                ])
            };
            let cores = arr(&s, "cores").len();
            // What this program IS, before what the machine is. It is the
            // first thing anyone opening "about" is actually looking for, and
            // it is the only place the repo and the version live at runtime.
            let mut al: Vec<Line> = vec![sect("this app")];
            al.push(kv2("name", format!("my-konsole-dash {}", env!("CARGO_PKG_VERSION"))));
            al.push(kv2("what", "a btop-shaped panel over one JSON snapshot".into()));
            let repo = "https://github.com/diegonmarcos/cloud-unix";
            // The product's own directory, not the repo root: cloud-unix holds
            // dozens of products and landing on the root leaves you to find
            // this one. The root is one click up from here anyway.
            al.push(kv2("repo", format!("{repo}/tree/main/da_my-konsole")));
            // Deep links: "da_my-konsole/dash" tells you where to look only if
            // you already have the tree checked out.
            al.push(kv2("source", format!("{repo}/tree/main/da_my-konsole/dash/src/dashboards")));
            al.push(kv2("watchdog source", format!("{repo}/tree/main/da_watchdog")));
            al.push(kv2("releases", format!("{repo}/releases")));
            al.push(kv2("this binary", format!("{repo}/releases/tag/my-konsole-latest")));
            al.push(kv2("watchdog binary", format!("{repo}/releases/tag/my-watchdog-latest")));
            al.push(kv2(
                "policy source",
                format!("{repo}/blob/main/da_watchdog/configs/watchdog-policy.json"),
            ));
            al.push(kv2(
                "publisher",
                // The split is the thing worth explaining here: this program
                // measures nothing, and every number on screen came from that
                // file.
                "my-watchdog — da_watchdog, its own product".into(),
            ));
            al.push(kv2("reads", snapshot_path()));
            al.push(kv2("built", format!("rustc target {}", std::env::consts::ARCH)));

            al.push(sect("system"));
            al.push(kv2("host", hi2("host")));
            al.push(kv2("user", hi2("user")));
            al.push(kv2("os", hi2("os")));
            al.push(kv2("kernel", hi2("kernel")));
            al.push(kv2("uptime", fmt_uptime(num(&s, "totals.since_s"))));
            al.push(kv2(
                "measured",
                match self.mesh.target() {
                    Some(a) => format!("{a}, over ssh — collected on demand"),
                    None => "locally — this is the hub".into(),
                },
            ));

            al.push(sect("hardware"));
            al.push(kv2("cpu", text(&s, "cpu_info.model")));
            let mhz = num_opt(&s, "cpu_info.mhz");
            al.push(kv2(
                "cores",
                match mhz {
                    Some(m) => format!("{cores} @ {:.2} GHz right now", m / 1000.0),
                    None => format!("{cores}"),
                },
            ));
            if let Some(t) = num_opt(&s, "cpu_info.temp_c") {
                let per = arr(&s, "cpu_info.core_temps");
                al.push(kv2(
                    "temperature",
                    if per.is_empty() {
                        format!("{t:.0}°C package")
                    } else {
                        format!(
                            "{t:.0}°C package · cores {}",
                            per.iter()
                                .filter_map(|v| v.as_f64())
                                .map(|v| format!("{v:.0}"))
                                .collect::<Vec<_>>()
                                .join(" ")
                        )
                    },
                ));
            }
            al.push(kv2("memory", fmt_gib(num(&s, "mem_detail.total"))));
            let vsrc = text(&s, "vram_detail.source");
            let vsize = |k: &str| -> Option<String> {
                num_opt(&s, &format!("vram_detail.{k}.total")).filter(|t| *t > 0.0).map(fmt_bytes_short)
            };
            match (vsize("dedicated"), vsize("shared")) {
                (None, None) => al.push(kv2(
                    "gpu memory",
                    // i915 keeps its usage in debugfs, which is root-only. Not
                    // knowing is a different answer from having none.
                    if vsrc == "none" { "not readable here (integrated, usage is root-only)".into() } else { "—".into() },
                )),
                (d, sh) => {
                    if let Some(d) = d {
                        al.push(kv2("gpu dedicated", d));
                    }
                    if let Some(sh) = sh {
                        al.push(kv2("gpu shared", sh));
                    }
                }
            }
            al.push(kv2("swap", fmt_gib(num(&s, "swap_detail.total"))));
            for pool in arr(&s, "storage") {
                let label = text(pool, "label");
                al.push(kv2(
                    if label.is_empty() { "storage" } else { "storage" },
                    format!(
                        "{} of {}{}",
                        fmt_g(num(pool, "alloc_used")),
                        fmt_g(num(pool, "dev_size")),
                        // "df" is the collector's label for a peer, where no
                        // qgroup data is gathered. Saying so beats letting a
                        // df number pass for a btrfs one.
                        if label == "df" { "  (df, not btrfs qgroups)" } else { "" }
                    ),
                ));
            }

            al.push(sect("network"));
            for i in arr(&s, "host_info.ifaces").iter().take(10) {
                al.push(kv2(&text(i, "name"), text(i, "addr")));
            }
            let pubip = hi2("public");
            al.push(kv2(
                "public",
                if pubip.is_empty() { "behind NAT — no routable address here".into() } else { pubip },
            ));
            al.push(kv2("gateway", format!("{} via {}", hi2("gateway"), hi2("wan_if"))));
            let dns: Vec<String> = arr(&s, "host_info.dns")
                .iter()
                .filter_map(|d| d.as_str().map(|x| x.to_string()))
                .collect();
            al.push(kv2("dns", if dns.is_empty() { "—".into() } else { dns.join("  ") }));
            let search: Vec<String> = arr(&s, "host_info.search")
                .iter()
                .filter_map(|d| d.as_str().map(|x| x.to_string()))
                .collect();
            if !search.is_empty() {
                al.push(kv2("search", search.join(" ")));
            }

            al.push(sect("running"));
            al.push(kv2("containers", format!("{}", arr(&s, "containers").len())));
            let svc = arr(&s, "services");
            let active = svc.iter().filter(|u| text(u, "active") == "active").count();
            al.push(kv2("units", format!("{active} active of {} declared", svc.len())));
            al.push(kv2("slices", format!("{}", arr(&s, "slices").len())));

            let max = (al.len() as u16).saturating_sub(ain.height);
            f.render_widget(
                Paragraph::new(al).scroll((self.detail_scroll.min(max), 0)),
                ain,
            );
            let status = Line::from(Span::styled(
                match &self.msg {
                    Some((m, _)) => format!(" {m}"),
                    None => " about · ↑↓ scroll · h keys · esc menu · ^c quits".to_string(),
                },
                Style::default().fg(LABEL),
            ));
            f.render_widget(Paragraph::new(status), rows[5]);
            self.render_overlays(f, area);
            return;
        }

        // ── containers-c ──────────────────────────────────────────────────────
        // Containers are processes too, but a container is not a row in the
        // process table: the thing you want named is the container, and what
        // it uses is the sum of everything inside it. docker already computes
        // that, so this shows docker's own numbers rather than re-deriving
        // them from cgroups and getting a subtly different answer.
        if self.docker {
            let (label, _) = CTR_SORT[self.ctr_sort.min(CTR_SORT.len() - 1)];
            let cb = tabbox(
                VIEW_TABS,
                tab("containers-c"),
                &format!(
                    "{label}{} · ←→ rank · i inv · enter acts",
                    if self.ctr_desc { "▼" } else { "▲" }
                ),
            );
            let cin = cb.inner(rows[4]);
            f.render_widget(cb, rows[4]);
            let cs = self.ctr_rows(&s);
            let _ = &label;
            if cs.is_empty() {
                f.render_widget(
                    Paragraph::new(vec![
                        Line::from(Span::styled(
                            "  no containers",
                            Style::default().fg(Color::Rgb(240, 160, 90)),
                        )),
                        Line::from(Span::styled(
                            "  nothing running, no docker or podman, or this user is not in the",
                            Style::default().fg(DIM),
                        )),
                        Line::from(Span::styled(
                            "  docker group — all three look the same from here, and all three",
                            Style::default().fg(DIM),
                        )),
                        Line::from(Span::styled("  mean the same thing.", Style::default().fg(DIM))),
                    ]),
                    cin,
                );
            } else {
                // Scroll, because oci-apps has 52 of these and a view that can
                // only ever show the first screenful is not a list.
                let vis = (cin.height as usize).saturating_sub(1).max(1);
                self.sel = self.sel.min(cs.len().saturating_sub(1));
                if self.sel < self.offset {
                    self.offset = self.sel;
                } else if self.sel >= self.offset + vis {
                    self.offset = self.sel + 1 - vis;
                }
                if self.offset + vis > cs.len() {
                    self.offset = cs.len().saturating_sub(vis);
                }
                let pct = |t: &str| -> f64 { t.trim_end_matches('%').parse().unwrap_or(0.0) };
                let crows: Vec<Row> = cs
                    .iter()
                    .enumerate()
                    .skip(self.offset)
                    .take(vis)
                    .map(|(n, c)| {
                        let sel = n == self.sel;
                        let base = if sel {
                            Style::default().bg(Color::Rgb(38, 48, 66)).add_modifier(Modifier::BOLD)
                        } else {
                            Style::default()
                        };
                        let cpu = pct(&text(c, "cpu"));
                        let mem = pct(&text(c, "mem_pct"));
                        // Empty is docker failing to read the cgroup, not zero.
                        let st = |k: &str, w: usize| -> String {
                            let v = text(c, k);
                            if v.is_empty() { format!("{:>w$}", "-") } else { format!("{v:>w$}") }
                        };
                        Row::new(vec![
                            Cell::from(format!(
                                "{}{}",
                                if sel { "▶" } else { " " },
                                trunc(&text(c, "name"), 22)
                            ))
                            .style(base.fg(Color::White)),
                            Cell::from(trunc(&text(c, "status"), 18)).style(base.fg(
                                if text(c, "state") == "running" {
                                    Color::Rgb(120, 220, 140)
                                } else {
                                    Color::Rgb(240, 160, 90)
                                },
                            )),
                            Cell::from(st("cpu", 7)).style(base.fg(grad(cpu / 100.0))),
                            Cell::from(st("mem_pct", 7)).style(base.fg(grad(mem / 100.0))),
                            {
                                let (used, _) = ctr_mem(&text(c, "mem"));
                                Cell::from(if used.is_empty() {
                                    format!("{:>10}", "-")
                                } else {
                                    format!("{used:>10}")
                                })
                                .style(base.fg(Color::Gray))
                            },
                            {
                                let (_, lim) = ctr_mem(&text(c, "mem"));
                                Cell::from(if lim.is_empty() {
                                    // No slash means no ceiling, which since
                                    // the caps came off is the normal case.
                                    format!("{:>10}", "none")
                                } else {
                                    format!("{lim:>10}")
                                })
                                .style(base.fg(DIM))
                            },
                            Cell::from(st("net", 19)).style(base.fg(Color::Rgb(120, 200, 255))),
                            Cell::from(st("block", 19)).style(base.fg(Color::Rgb(220, 140, 240))),
                            Cell::from(st("pids", 5)).style(base.fg(DIM)),
                            Cell::from(trunc(&text(c, "ports"), 30))
                                .style(base.fg(Color::Rgb(150, 170, 200))),
                            Cell::from(format!("{:>8}", text(c, "image_size"))).style(base.fg(Color::Gray)),
                            Cell::from(trunc(&text(c, "image"), 40)).style(base.fg(DIM)),
                        ])
                    })
                    .collect();
                let table = Table::new(
                    crows,
                    [
                        Constraint::Length(23),
                        Constraint::Length(19),
                        Constraint::Length(8),
                        Constraint::Length(8),
                        Constraint::Length(11),
                        Constraint::Length(11),
                        Constraint::Length(20),
                        Constraint::Length(20),
                        Constraint::Length(6),
                        Constraint::Length(31),
                        Constraint::Length(9),
                        Constraint::Min(12),
                    ],
                )
                // The ranked column is marked, exactly like the process
                // header: ←/→ moving a sort you cannot see is a gesture with
                // no feedback.
                .header(Row::new(
                    [
                        "CONTAINER", "STATUS", "CPU%", "MEM%", "MEM USED", "MEM MAX", "NET I/O",
                        "BLOCK I/O", "PIDS", "PORTS", "ON DISK", "IMAGE",
                    ]
                    .map(|h| {
                        if h == label {
                            Cell::from(format!("{h}{}", if self.ctr_desc { "▼" } else { "▲" }))
                                .style(
                                    Style::default()
                                        .fg(Color::Rgb(120, 200, 255))
                                        .add_modifier(Modifier::BOLD),
                                )
                        } else {
                            Cell::from(h).style(Style::default().fg(LABEL))
                        }
                    }),
                ));
                f.render_widget(table, cin);
            }
            let status = Line::from(Span::styled(
                match &self.msg {
                    Some((m, _)) => format!(" {m}"),
                    None => format!(
                        " {} containers · {} of them · ↑↓ to move · enter for detail and actions",
                        cs.len(),
                        self.sel + 1
                    ),
                },
                Style::default().fg(LABEL),
            ));
            f.render_widget(Paragraph::new(status), rows[5]);
            self.render_overlays(f, area);
            return;
        }

        // ── containers-i ──────────────────────────────────────────────────────
        // A container list answers "what is running". It cannot answer "what is
        // this costing me on disk", because the images nothing runs are exactly
        // the ones nobody notices — so those get their own tab and are called
        // out by name.
        if self.images {
            let (ilabel, _) = IMG_SORT[self.img_sort.min(IMG_SORT.len() - 1)];
            let ib = tabbox(
                VIEW_TABS,
                tab("containers-i"),
                &format!(
                    "{ilabel}{} · ←→ rank · i inv · enter acts",
                    if self.img_desc { "▼" } else { "▲" }
                ),
            );
            let iin = ib.inner(rows[4]);
            f.render_widget(ib, rows[4]);
            let imgs = arr(&s, "images");
            if imgs.is_empty() {
                f.render_widget(
                    Paragraph::new(Line::from(Span::styled(
                        "  no images — nothing pulled here, or no docker this user can reach",
                        Style::default().fg(Color::Rgb(240, 160, 90)),
                    ))),
                    iin,
                );
            } else {
                let used: std::collections::HashSet<String> =
                    arr(&s, "containers").iter().map(|c| text(c, "image")).collect();
                let vis = (iin.height as usize).saturating_sub(1).max(1);
                self.sel = self.sel.min(imgs.len().saturating_sub(1));
                if self.sel < self.offset {
                    self.offset = self.sel;
                } else if self.sel >= self.offset + vis {
                    self.offset = self.sel + 1 - vis;
                }
                if self.offset + vis > imgs.len() {
                    self.offset = imgs.len().saturating_sub(vis);
                }
                let irows: Vec<Row> = self
                    .img_rows(&s)
                    .into_iter()
                    .enumerate()
                    .skip(self.offset)
                    .take(vis)
                    .map(|(n, i)| {
                        let sel = n == self.sel;
                        let base = if sel {
                            Style::default().bg(Color::Rgb(38, 48, 66)).add_modifier(Modifier::BOLD)
                        } else {
                            Style::default()
                        };
                        let full = format!("{}:{}", text(i, "repo"), text(i, "tag"));
                        let idle = !used.contains(&full);
                        Row::new(vec![
                            Cell::from(format!(
                                "{}{}",
                                if sel { "▶" } else { " " },
                                trunc(&full, 51)
                            ))
                            .style(base.fg(if idle { Color::Rgb(150, 140, 110) } else { Color::Gray })),
                            Cell::from(format!("{:>9}", text(i, "size"))).style(base.fg(Color::White)),
                            Cell::from(format!("{:>16}", text(i, "created"))).style(base.fg(DIM)),
                            Cell::from(text(i, "id")).style(base.fg(DIM)),
                            Cell::from(if idle { "nothing runs this" } else { "" })
                                .style(base.fg(Color::Rgb(240, 160, 90))),
                        ])
                    })
                    .collect();
                let itable = Table::new(
                    irows,
                    [
                        Constraint::Length(53),
                        Constraint::Length(10),
                        Constraint::Length(17),
                        Constraint::Length(14),
                        Constraint::Min(10),
                    ],
                )
                .header(Row::new(["IMAGE", "SIZE", "CREATED", "ID", ""].map(|h| {
                    if h == ilabel {
                        Cell::from(format!("{h}{}", if self.img_desc { "▼" } else { "▲" })).style(
                            Style::default()
                                .fg(Color::Rgb(120, 200, 255))
                                .add_modifier(Modifier::BOLD),
                        )
                    } else {
                        Cell::from(h).style(Style::default().fg(LABEL))
                    }
                })));
                f.render_widget(itable, iin);
            }
            let status = Line::from(Span::styled(
                match &self.msg {
                    Some((m, _)) => format!(" {m}"),
                    None => format!(
                        " {} images · ↑↓ to move · enter for detail and actions",
                        arr(&s, "images").len()
                    ),
                },
                Style::default().fg(LABEL),
            ));
            f.render_widget(Paragraph::new(status), rows[5]);
            self.render_overlays(f, area);
            return;
        }

        // ── history ───────────────────────────────────────────────────────────
        // What this machine actually did, rather than what it is doing. The
        // daemon keeps the series and computes the window; the panel only
        // renders it, so a peer would answer the same way if it kept one.
        if self.history {
            let hb = tabbox(VIEW_TABS, tab("history"), "y back to processes");
            let hin = hb.inner(rows[4]);
            f.render_widget(hb, rows[4]);
            let win = num(&s, "history.window_s");
            let n = num(&s, "history.samples");
            let mut hl: Vec<Line> = vec![];
            if n < 2.0 {
                hl.push(Line::from(Span::styled(
                    "  no history yet — the daemon records one sample a minute, and needs two to measure anything",
                    Style::default().fg(Color::Rgb(240, 160, 90)),
                )));
                if !self.mesh.target().is_none() {
                    hl.push(Line::from(Span::styled(
                        "  (a peer collected over ssh keeps no history: it is sampled on demand, not continuously)",
                        Style::default().fg(DIM),
                    )));
                }
            } else {
                let row = |k: &str, v: String, per: String, c: Color| -> Line<'static> {
                    Line::from(vec![
                        Span::styled(format!("  {k:<22}"), Style::default().fg(LABEL)),
                        Span::styled(format!("{v:>12}"), Style::default().fg(c)),
                        Span::styled(format!("   {per}"), Style::default().fg(DIM)),
                    ])
                };
                let h = |k: &str| num(&s, &format!("history.{k}"));
                let hours = win / 3600.0;
                let rate = |b: f64| format!("{}/h", fmt_bytes_short(b / hours.max(0.01)));
                hl.push(Line::from(Span::styled(
                    format!(
                        "  covering {} · {} samples · one a minute",
                        fmt_uptime(win),
                        n as i64
                    ),
                    Style::default().fg(Color::Gray),
                )));
                hl.push(Line::from(""));
                hl.push(Line::from(Span::styled(
                    "moved",
                    Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
                )));
                hl.push(row("downloaded", fmt_bytes_short(h("net_rx_bytes")), rate(h("net_rx_bytes")), Color::Rgb(120, 200, 255)));
                hl.push(row("uploaded", fmt_bytes_short(h("net_tx_bytes")), rate(h("net_tx_bytes")), Color::Rgb(240, 169, 66)));
                hl.push(row("read from disk", fmt_bytes_short(h("disk_read_bytes")), rate(h("disk_read_bytes")), Color::Rgb(120, 220, 140)));
                hl.push(row("written to disk", fmt_bytes_short(h("disk_write_bytes")), rate(h("disk_write_bytes")), Color::Rgb(220, 140, 240)));
                hl.push(Line::from(""));
                hl.push(Line::from(Span::styled(
                    "held",
                    Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD),
                )));
                // Time-weighted, which is what a percentage averaged over a
                // day has to mean when it is sampled once a minute.
                let cpu_avg = h("cpu_pct_avg");
                hl.push(row(
                    "cpu, time-weighted",
                    format!("{cpu_avg:.2}%"),
                    format!("≈ {} of one core busy", fmt_uptime(cpu_avg / 100.0 * win)),
                    grad(cpu_avg / 100.0),
                ));
                let mem_avg = h("mem_pct_avg");
                hl.push(row("memory, time-weighted", format!("{mem_avg:.2}%"), String::new(), grad(mem_avg / 100.0)));
                let swap_avg = h("swap_pct_avg");
                hl.push(row("swap, time-weighted", format!("{swap_avg:.2}%"), String::new(), grad(swap_avg / 100.0)));
                hl.push(Line::from(""));
                hl.push(row(
                    "up",
                    fmt_uptime(num(&s, "totals.since_s")),
                    "since boot".into(),
                    Color::Gray,
                ));
                hl.push(Line::from(Span::styled(
                    "  counters that went backwards are treated as a reboot and not counted across",
                    Style::default().fg(DIM),
                )));
            }
            f.render_widget(Paragraph::new(hl), hin);
            let status = Line::from(Span::styled(
                match &self.msg {
                    Some((m, _)) => format!(" {m}"),
                    None => " last 24 hours · h keys · esc menu · ^c quits".to_string(),
                },
                Style::default().fg(LABEL),
            ));
            f.render_widget(Paragraph::new(status), rows[5]);
            self.render_overlays(f, area);
            return;
        }

        // ── fleet ─────────────────────────────────────────────────────────────
        // The whole mesh in one table, instead of one machine in detail. Rows
        // come from the same collector the measure-a-peer path uses, so a peer
        // is described by its own /proc rather than by anything guessed here.
        if self.fleet {
            let fb = tabbox(VIEW_TABS, tab("fleet"), "enter opens a machine · esc → measure");
            let fin = fb.inner(rows[4]);
            f.render_widget(fb, rows[4]);
            let got = self.mesh.fleet();
            let peers = self.mesh.list();
            let mut frows: Vec<Row> = vec![];
            for (fi, p) in peers.iter().enumerate() {
                // Without this the cursor moves and nothing on screen says so,
                // which reads as arrow keys that do not work.
                let fsel = fi == self.sel;
                let base = if fsel {
                    Style::default().bg(Color::Rgb(38, 48, 66)).add_modifier(Modifier::BOLD)
                } else {
                    Style::default()
                };
                // This machine is described by the snapshot already on screen;
                // there is no reason to ssh to ourselves to learn it.
                let res = if p.local { Some(Ok(s.clone())) } else { got.get(&p.alias).cloned() };
                let snap = match &res {
                    Some(Ok(v)) => Some(v.clone()),
                    _ => None,
                };
                let name = Span::styled(
                    // 17 plus the cursor mark: "oci-analytics-pub" is 17 and
                    // was losing its tail before that.
                    format!("{}{:<17}", if fsel { "▶" } else { " " }, trunc(&p.alias, 17)),
                    base.fg(if p.local { Color::Rgb(120, 200, 255) } else { Color::White }),
                );
                let addr = Span::styled(format!("{:<16}", p.ip), base.fg(DIM));
                let Some(v) = snap else {
                    // Reachable but not yet collected, or not reachable at all
                    // — two different states and they must not read the same.
                    // Spans, not a second cell: the status is a sentence and
                    // the RTT column is eight characters wide, which turned
                    // "unreachable" into "unreacha".
                    frows.push(Row::new(vec![Cell::from(Line::from(vec![
                        name,
                        addr,
                        match &res {
                            // Reached and refused is not the same as not yet
                            // reached, and the reason is the useful part.
                            Some(Err(e)) => Span::styled(
                                trunc(e, 74),
                                Style::default().fg(Color::Rgb(240, 160, 90)),
                            ),
                            _ if p.local => Span::styled("—".to_string(), Style::default().fg(LABEL)),
                            _ if !p.probed => {
                                Span::styled("probing…".to_string(), Style::default().fg(LABEL))
                            }
                            _ if p.up => Span::styled(
                                "reachable · collecting…".to_string(),
                                Style::default().fg(LABEL),
                            ),
                            _ => Span::styled(
                                "unreachable".to_string(),
                                Style::default().fg(Color::Rgb(240, 72, 72)),
                            ),
                        },
                    ]))]));
                    continue;
                };
                let g = |k: &str| num(&v, k);
                let pct = |x: f64| Cell::from(z(x, 5, format!("{x:>5.1}"))).style(base.fg(grad(x / 100.0)));
                let ncpu = arr(&v, "cores").len().max(1) as f64;
                let l1 = g("load1");
                frows.push(Row::new(vec![
                    Cell::from(Line::from(vec![name, addr])),
                    Cell::from(if p.local {
                        format!("{:>7}", "here")
                    } else if p.up {
                        format!("{:>6.0}ms", p.rtt_ms)
                    } else {
                        format!("{:>7}", "down")
                    })
                    .style(base.fg(DIM)),
                    pct(g("cpu")),
                    pct(g("mem")),
                    pct(g("swap")),
                    // Absent is not zero: most of this fleet has no readable
                    // GPU memory at all, and a 0% bar would claim a measurement.
                    {
                        let vg = |k: &str| -> Option<f64> {
                            let u = num_opt(&v, &format!("vram_detail.{k}.used"))?;
                            let t = num_opt(&v, &format!("vram_detail.{k}.total"))?;
                            if t > 0.0 { Some(u / t * 100.0) } else { None }
                        };
                        Cell::from(Line::from(vec![
                            Span::styled(
                                match vg("dedicated") {
                                    Some(x) => format!("{x:>5.1}"),
                                    None => format!("{:>5}", "-"),
                                },
                                Style::default().fg(grad(vg("dedicated").unwrap_or(0.0) / 100.0)),
                            ),
                            Span::styled(
                                match vg("shared") {
                                    Some(x) => format!(" {x:>5.1}"),
                                    None => format!(" {:>5}", "-"),
                                },
                                Style::default().fg(grad(vg("shared").unwrap_or(0.0) / 100.0)),
                            ),
                        ]))
                    },
                    Cell::from(format!("{:>6.1}G", num(&v, "mem_detail.total"))).style(base.fg(Color::Gray)),
                    // btrfs allocates in chunks and df cannot see that, so on a
                    // machine that publishes storage the pool figure is the
                    // true one; peers fall back to their own df.
                    pct(match arr(&v, "storage").first() {
                        Some(st) if num(st, "dev_size") > 0.0 => {
                            num(st, "alloc_used") / num(st, "dev_size") * 100.0
                        }
                        _ => g("disk"),
                    }),
                    // All three loads, like uptime(1) — one number cannot tell
                    // a spike from a machine that has been buried for an hour.
                    Cell::from(Line::from(vec![
                        Span::styled(format!("{l1:>5.2}"), Style::default().fg(grad(l1 / ncpu))),
                        Span::styled(
                            format!(" {:>5.2} {:>5.2}", g("load5"), g("load15")),
                            Style::default().fg(Color::Gray),
                        ),
                    ])),
                    Cell::from(format!("{:>4.0}", ncpu)).style(base.fg(DIM)),
                    // some-cpu, full-io, full-mem at 10s: the three that
                    // actually tell you what a machine is stuck on. `full`
                    // for io and memory because that is every task stalled,
                    // which is the figure that tracked the freeze.
                    Cell::from(Line::from(vec![
                        Span::styled(
                            format!("{:>6.2}", g("psi.cpu.some10")),
                            Style::default().fg(grad(g("psi.cpu.some10") / 60.0)),
                        ),
                        Span::styled(
                            format!(" {:>6.2}", g("psi.io.full10")),
                            Style::default().fg(grad(g("psi.io.full10") / 20.0)),
                        ),
                        Span::styled(
                            format!(" {:>6.2}", g("psi.memory.full10")),
                            Style::default().fg(grad(g("psi.memory.full10") / 20.0)),
                        ),
                    ])),
                    Cell::from(format!("{:>6}", arr(&v, "proc_table").len())).style(base.fg(DIM)),
                ]));
            }
            let ftable = Table::new(
                frows,
                [
                    Constraint::Length(56), // peer + address + status
                    Constraint::Length(8),  // rtt
                    Constraint::Length(5),  // cpu
                    Constraint::Length(5),  // mem
                    Constraint::Length(5),  // swap
                    Constraint::Length(12), // vram d/s
                    Constraint::Length(7),  // ram total
                    Constraint::Length(5),  // disk
                    Constraint::Length(17), // load 1/5/15
                    Constraint::Length(4),  // cores
                    Constraint::Length(20), // psi cpu/io/mem
                    Constraint::Length(6),  // procs
                ],
            )
            .header(Row::new(vec![
                Cell::from("PEER              ADDRESS").style(Style::default().fg(LABEL)),
                Cell::from("     RTT").style(Style::default().fg(LABEL)),
                Cell::from(" CPU%").style(Style::default().fg(LABEL)),
                Cell::from(" MEM%").style(Style::default().fg(LABEL)),
                Cell::from("SWAP%").style(Style::default().fg(LABEL)),
                Cell::from("VRAM-d VRAM-s").style(Style::default().fg(LABEL)),
                Cell::from("    RAM").style(Style::default().fg(LABEL)),
                Cell::from("DISK%").style(Style::default().fg(LABEL)),
                Cell::from(" LOAD  1     5    15").style(Style::default().fg(LABEL)),
                Cell::from("CPUS").style(Style::default().fg(LABEL)),
                Cell::from("PSI cpu     io    mem").style(Style::default().fg(LABEL)),
                Cell::from(" PROCS").style(Style::default().fg(LABEL)),
            ]));
            f.render_widget(ftable, fin);
            let status = Line::from(Span::styled(
                match &self.msg {
                    Some((m, _)) => format!(" {m}"),
                    None => format!(
                        " {} peers · ↑↓ to move · enter for the whole machine · swept every 20s",
                        peers.len()
                    ),
                },
                Style::default().fg(LABEL),
            ));
            f.render_widget(Paragraph::new(status), rows[5]);
            self.render_overlays(f, area);
            return;
        }

        // ── processes ─────────────────────────────────────────────────────────
        // Sorted against the local clone `s`, so self stays free to mutate for
        // the scroll bookkeeping just below.
        let sorted = sort_procs(&s, self.sort, self.desc, self.win);
        let sorted: Vec<&Value> = if self.orphans || self.zombies {
            sorted.into_iter().filter(|p| Self::is_lost(p)).collect()
        } else {
            sorted
        };
        // Depth rides along even when the tree is off, so the row builder does
        // not need two shapes; it is simply 0 for every row.
        let procs: Vec<(&Value, usize)> = if self.tree {
            tree_order(&sorted, arr(&s, "proc_spine"))
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
            "{}{} · {} · {}{}←→ column · i inv · w win · t tree · x free · enter details · k act · h help",
            self.sort.label(),
            if self.desc { "▼" } else { "▲" },
            self.win.label(),
            if self.tree { "tree · " } else { "" },
            if self.orphans { "ORPHANS ONLY · " } else { "" },
        );
        let proc_b = tabbox(
            VIEW_TABS,
            tab(if self.zombies { "zombies" } else if self.tree { "tree" } else { "proc" }),
            &hint,
        );
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
                // A spine row is an ancestor the daemon added to complete the
                // tree, not a measured process. It has a pid, a ppid and a
                // name and nothing else, so every metric cell stays blank.
                let spine = p.get("cpu_pct").is_none();
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
                } else if spine || prot {
                    Style::default().fg(DIM)
                } else {
                    Style::default()
                };
                if spine {
                    let mut c = vec![
                        Cell::from(format!("{}", num(p, "pid") as i64)).style(base),
                        Cell::from("").style(base),
                        Cell::from("").style(base),
                        Cell::from(name).style(base),
                    ];
                    c.extend((0..12).map(|_| Cell::from("").style(base)));
                    return Row::new(c);
                }
                Row::new(vec![
                    Cell::from(format!("{}", num(p, "pid") as i64)).style(base.fg(if sel { Color::White } else { LABEL })),
                    Cell::from(text(p, "slice")).style(base.fg(if sel { Color::White } else { DIM })),
                    Cell::from(text(p, "user")).style(base.fg(if sel { Color::White } else { LABEL })),
                    Cell::from(name).style(base),
                    Cell::from(zp(cpu, 5)).style(base.fg(grad(cpu / 100.0))),
                    Cell::from(zp(a("10s", "cpu_pct"), 5)).style(base.fg(grad(a("10s", "cpu_pct") / 100.0))),
                    Cell::from(zp(a("1m", "cpu_pct"), 5)).style(base.fg(grad(a("1m", "cpu_pct") / 100.0))),
                    Cell::from(zp(memp, 5)).style(base.fg(grad(memp / 100.0))),
                    Cell::from(zp(a("10s", "mem_pct"), 5)).style(base.fg(grad(a("10s", "mem_pct") / 100.0))),
                    Cell::from(zp(a("1m", "mem_pct"), 5)).style(base.fg(grad(a("1m", "mem_pct") / 100.0))),
                    Cell::from(fmt_mem_cell(rss)).style(base.fg(Color::Gray)),
                    // null when the daemon could not read another user's
                    // smaps_rollup. A dash, not a zero — we do not know.
                    Cell::from(match num_opt(p, "mem_pss_bytes") {
                        Some(v) => fmt_mem_cell(v),
                        None => "    —".into(),
                    })
                    .style(base.fg(Color::Rgb(150, 170, 200))),
                    Cell::from(fmt_bps(num(p, "net_rx_bytes_per_s"))).style(base.fg(Color::Rgb(120, 200, 255))),
                    Cell::from(fmt_bps(num(p, "net_tx_bytes_per_s"))).style(base.fg(Color::Rgb(240, 169, 66))),
                    Cell::from(fmt_bps(rd)).style(base.fg(Color::Rgb(120, 220, 140))),
                    Cell::from(fmt_bps(wr)).style(base.fg(Color::Rgb(220, 140, 240))),
                    // runq is a pressure share, not a load percentage: a
                    // tenth of a percent of stall time is still a real signal
                    // and keeps its digits.
                    Cell::from(z(rq, 5, format!("{rq:>5.2}"))).style(base.fg(grad(rq / 20.0))),
                ])
            })
            .collect();

        // Everything a unit row can honestly say: it has no pid, no rss and no
        // rates. Blanks rather than zeroes — a zero here would read as a
        // measurement, and there is nothing being measured.
        let mut trows = trows;
        let ustart = self.offset.saturating_sub(procs.len());
        for (j, u) in units.iter().enumerate().skip(ustart).take(vis.saturating_sub(trows.len())) {
            if let Some(h) = u.heading {
                let mut c = vec![
                    Cell::from("").style(Style::default()),
                    Cell::from("").style(Style::default()),
                    Cell::from("").style(Style::default()),
                    Cell::from(format!("── {h} ──"))
                        .style(Style::default().fg(Color::Rgb(120, 200, 255)).add_modifier(Modifier::BOLD)),
                ];
                c.extend((0..13).map(|_| Cell::from("")));
                trows.push(Row::new(c));
                continue;
            }
            let (name, scope, state) = (&u.name, &u.scope, &u.state);
            let sel = procs.len() + j == self.sel;
            let failed = state.starts_with("failed");
            let base = if sel {
                Style::default().bg(Color::Rgb(38, 48, 66)).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(DIM)
            };
            // Dead-but-declared reads as a warning, not as debris: something
            // that is supposed to be running is not. Oneshots that already
            // exited, and units that are merely idle, stay quiet.
            let sc = if failed {
                Color::Rgb(240, 72, 72)
            } else if state.starts_with("inactive") || state.starts_with("not-loaded") {
                Color::Rgb(240, 160, 90)
            } else {
                Color::Rgb(120, 128, 145)
            };
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
            hdr("RSS", Sort::Rss),
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
        self.render_overlays(f, area);
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

    // The whole point of the keybinding tables: a key cannot be advertised in
    // one place and handled in another, and it cannot collide with a key the
    // frame already took. "about" was bound to 'a' — listed in the tab strip
    // AND in the help, and swallowed by frame.rs for auto-refresh before the
    // dashboard ever saw it, so the view was simply unreachable. This fails if
    // that is ever true again.
    #[test]
    fn no_keybinding_collides_with_the_frame_or_itself() {
        let mut seen: Vec<(char, &str)> = Vec::new();
        for (name, k) in VIEW_TABS {
            seen.push((*k, name));
        }
        for (k, _, d) in SORT_KEYS {
            seen.push((*k, d));
        }
        // The single-character entries in OTHER_KEYS are real bindings too;
        // the multi-key ones ("← →", "pgup pgdn") describe non-char keys.
        for (sec, k, d) in OTHER_KEYS {
            if *sec == "modal" {
                continue;
            }
            let mut ch = k.chars();
            if let (Some(c), None) = (ch.next(), ch.next()) {
                seen.push((c, d));
            }
        }
        for (c, what) in &seen {
            assert!(
                !FRAME_RESERVED.contains(c),
                "{c:?} ({what}) is reserved by frame.rs — it would never reach this dashboard"
            );
        }
        for (i, (c, a)) in seen.iter().enumerate() {
            for (d, b) in seen.iter().skip(i + 1) {
                assert_ne!(c, d, "{c:?} is bound twice: {a} and {b}");
            }
        }
    }

    // ←/→ walks the header left to right and wraps. If step() ever clamped
    // instead, the two ends of the header would be dead keys.
    #[test]
    fn arrows_walk_the_sort_columns_and_wrap() {
        // Relative order, not fixed neighbours: every new column inserted in
        // the header used to break this test for no reason. What must hold is
        // that SORT_ORDER reads left to right the way the header does.
        let at = |k: Sort| SORT_ORDER.iter().position(|x| *x == k).expect("column is sortable");
        let header_order = [
            Sort::Pid, Sort::Slice, Sort::User, Sort::Name, Sort::Cpu,
            Sort::C10s, Sort::C60s, Sort::Mem, Sort::M10s, Sort::M60s,
            Sort::Pss, Sort::Net, Sort::Disk, Sort::Runq,
        ];
        for w in header_order.windows(2) {
            assert!(at(w[0]) < at(w[1]), "{:?} must sort before {:?}", w[0], w[1]);
        }
        // and one step really is one column
        assert_eq!(SORT_ORDER[at(Sort::Cpu) + 1], Sort::Cpu.step(1));
        assert_eq!(Sort::Cpu.step(1).step(-1), Sort::Cpu);
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
    fn braille_zero_is_a_baseline_and_full_is_solid() {
        // Zero is a flat baseline, not an empty box. Counting glyphs in btop's
        // own output says 85% of what it emits is exactly this character, and
        // it is what makes an idle graph read as a graph.
        const FLOOR: char = '\u{28C0}'; // dots 7,8 — the bottom sub-row
        let z = braille_graph(&vec![0.0; 8], 100.0, 4, 2);
        assert_eq!(z.len(), 2);
        for sp in &z[0].spans {
            assert_eq!(sp.content.chars().next().unwrap(), BLANK, "top row stays empty");
        }
        for sp in &z[1].spans {
            assert_eq!(sp.content.chars().next().unwrap(), FLOOR, "bottom row is the floor");
            // And it is GREY. Colouring the floor by its height is what made
            // the graph one continuous green band; btop spends the gradient
            // only where a value reaches.
            assert_eq!(sp.style.fg, Some(GRAPH_FLOOR), "the floor is not a value");
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
        let _ = &g;
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
        // The empty part of the history is the floor, not nothing — but it is
        // still visibly not the data, which is the point of the check.
        assert_eq!(chars[0], '\u{28C0}');
        assert_eq!(chars[2], '\u{28C0}');
        assert_eq!(chars[3], '\u{28FF}');
        // grey where it is padding, coloured only where the samples are
        assert_eq!(g[0].spans[0].style.fg, Some(GRAPH_FLOOR));
        assert_ne!(g[0].spans[3].style.fg, Some(GRAPH_FLOOR));
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

    // The YAML is hand-written, so the thing that can go wrong is quoting: a
    // string that looks like a number, a bool or a comment has to come back as
    // a string, and one that does not must stay bare or the whole point (token
    // count) is lost. Structure is checked at the same time, since a map value
    // that is itself a map has to start on the next line and a scalar must not.
    #[test]
    fn yaml_quotes_only_what_would_change_meaning() {
        let v = json!({
            "host": "surface-nixos",
            "version": "1.20",
            "flag": "true",
            "cmd": "sh -c x",
            "arg": "--no-tray",
            "note": "a: b",
            "empty": "",
            "cpu": 12.5,
            "on": true,
            "gone": null,
            "list": ["a", "b"],
            "nested": {"k": "v"},
            "blank": {},
        });
        let mut y = String::new();
        export::to_yaml(&v, 0, &mut y);

        // Bare: nothing here reparses as another type.
        assert!(y.contains("host: surface-nixos"), "{y}");
        // Quoted: these would come back as f64 / bool / a mapping / nothing.
        assert!(y.contains("version: \"1.20\""), "{y}");
        assert!(y.contains("flag: \"true\""), "{y}");
        assert!(y.contains("note: \"a: b\""), "{y}");
        assert!(y.contains("empty: \"\""), "{y}");
        // A leading '-' opens a sequence entry, so that one has to be quoted.
        assert!(y.contains("arg: \"--no-tray\""), "{y}");
        // ...but an interior dash is harmless, and quoting it would be exactly
        // the over-quoting this format exists to avoid.
        assert!(y.contains("cmd: sh -c x"), "{y}");
        // Non-strings are never quoted — they are already the right type.
        assert!(y.contains("cpu: 12.5") && y.contains("gone: null"), "{y}");
        // Blocks open on the next line, one space deeper; empties stay inline.
        assert!(y.contains("nested:\n k: v"), "{y}");
        assert!(y.contains("list:\n - a\n - b"), "{y}");
        assert!(y.contains("blank: {}"), "{y}");
    }
}
