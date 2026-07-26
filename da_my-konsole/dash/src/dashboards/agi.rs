// AGI — Claude Code usage analytics (cloud-terminal AGI port). Scans
// ~/.claude/projects/**/*.jsonl transcripts for token usage.
use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::frame::Dashboard;
use crate::ui::block;
use super::sh;

const ACTIVE_SECS: u64 = 5 * 60; // mtime within 5min = still-running session

#[derive(Default, Clone)]
struct Usage { input: u64, output: u64, cache_r: u64, cache_w: u64, msgs: u64 }

#[derive(Clone)]
struct SessionInfo { name: String, age_secs: u64, msgs: u64, tokens: u64 }

pub struct Agi {
    total: Usage,
    by_model: BTreeMap<String, Usage>,
    sessions: usize,
    recent: Vec<SessionInfo>,   // sorted newest-first
    active: usize,
    by_day: [u64; 7],           // tokens, index 0 = today
}

impl Agi {
    pub fn new() -> Self {
        Agi { total: Usage::default(), by_model: BTreeMap::new(), sessions: 0, recent: Vec::new(), active: 0, by_day: [0; 7] }
    }
}

fn add(u: &mut Usage, usage: &serde_json::Value) {
    u.input += usage.get("input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
    u.output += usage.get("output_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
    u.cache_r += usage.get("cache_read_input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
    u.cache_w += usage.get("cache_creation_input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
    u.msgs += 1;
}

fn age_label(secs: u64) -> String {
    if secs < 60 { format!("{secs}s ago") }
    else if secs < 3600 { format!("{}m ago", secs / 60) }
    else if secs < 86400 { format!("{}h ago", secs / 3600) }
    else { format!("{}d ago", secs / 86400) }
}

impl Dashboard for Agi {
    fn title(&self) -> String { "🤖 agi".into() }
    fn tick_ms(&self) -> u64 { 8000 }

    fn update(&mut self) {
        self.total = Usage::default();
        self.by_model.clear();
        self.sessions = 0;
        self.active = 0;
        self.by_day = [0; 7];
        let mut sessions: Vec<SessionInfo> = Vec::new();
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
        let files = sh("find $HOME/.claude/projects -name '*.jsonl' -mtime -30 2>/dev/null");
        for path in files.lines() {
            self.sessions += 1;
            let mtime = std::fs::metadata(path).ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(now);
            let age = now.saturating_sub(mtime);
            if age <= ACTIVE_SECS { self.active += 1; }
            let day = (age / 86400).min(6) as usize;

            let Ok(txt) = std::fs::read_to_string(path) else { continue };
            let mut s_msgs = 0u64;
            let mut s_tokens = 0u64;
            for line in txt.lines() {
                let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
                let Some(usage) = v.pointer("/message/usage") else { continue };
                add(&mut self.total, usage);
                let model = v.pointer("/message/model").and_then(|m| m.as_str()).unwrap_or("?").to_string();
                add(self.by_model.entry(model).or_default(), usage);
                let tin = usage.get("input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
                let tout = usage.get("output_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
                s_msgs += 1;
                s_tokens += tin + tout;
                self.by_day[day] += tin + tout;
            }
            let name = std::path::Path::new(path)
                .parent().and_then(|p| p.file_name()).and_then(|s| s.to_str())
                .unwrap_or("?").chars().take(32).collect();
            sessions.push(SessionInfo { name, age_secs: age, msgs: s_msgs, tokens: s_tokens });
        }
        sessions.sort_by_key(|s| s.age_secs);
        sessions.truncate(15);
        self.recent = sessions;
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        let rows = Layout::vertical([
            Constraint::Length(4),
            Constraint::Length(9),
            Constraint::Min(6),
            Constraint::Length(9),
        ]).split(area);
        let t = &self.total;
        let k = |n: u64| if n >= 1_000_000 { format!("{:.1}M", n as f64 / 1e6) } else { format!("{:.0}K", n as f64 / 1e3) };
        let tiles = vec![
            Line::from(vec![
                Span::styled(format!("  sessions {} ", self.sessions), Style::default().fg(Color::Cyan)),
                Span::styled(format!("  active now {} ", self.active), Style::default().fg(Color::Green)),
                Span::styled(format!("  messages {}  ", t.msgs), Style::default().fg(Color::Gray)),
            ]),
            Line::from(vec![
                Span::styled(format!("  in {}  ", k(t.input)), Style::default().fg(Color::Green)),
                Span::styled(format!("  out {}  ", k(t.output)), Style::default().fg(Color::Yellow)),
                Span::styled(format!("  cache-r {}  ", k(t.cache_r)), Style::default().fg(Color::Blue)),
                Span::styled(format!("  cache-w {}  ", k(t.cache_w)), Style::default().fg(Color::Magenta)),
            ]),
        ];
        f.render_widget(Paragraph::new(tiles).block(block("TOTAL (last 30d)")), rows[0]);

        let day_names = ["Today", "Yesterday", "2d ago", "3d ago", "4d ago", "5d ago", "6d ago"];
        let days: Vec<Line> = (0..7).map(|i| {
            let toks = self.by_day[i];
            let bar_len = if t.input + t.output == 0 { 0 } else { (toks * 40 / (self.by_day.iter().copied().max().unwrap_or(1).max(1))) as usize };
            Line::from(vec![
                Span::styled(format!("{:<10}", day_names[i]), Style::default().fg(Color::Gray)),
                Span::styled("█".repeat(bar_len), Style::default().fg(Color::Cyan)),
                Span::raw(format!(" {}", k(toks))),
            ])
        }).collect();
        f.render_widget(Paragraph::new(days).block(block("TOKENS/DAY (last 7d)")), rows[1]);

        let sessions: Vec<Line> = self.recent.iter().map(|s| Line::from(vec![
            Span::styled(format!("{:<32} ", s.name), Style::default().fg(if s.age_secs <= ACTIVE_SECS { Color::Green } else { Color::Cyan })),
            Span::raw(format!("{:<10} msgs {:<5} tokens {}", age_label(s.age_secs), s.msgs, k(s.tokens))),
        ])).collect();
        f.render_widget(Paragraph::new(sessions).block(block("LAST 15 SESSIONS")), rows[2]);

        let models: Vec<Line> = self.by_model.iter().map(|(m, u)| {
            let short: String = m.rsplit('/').next().unwrap_or(m).chars().take(28).collect();
            Line::from(vec![
                Span::styled(format!("{short:<28} "), Style::default().fg(Color::Cyan)),
                Span::raw(format!("msgs {:<6} in {:<7} out {:<7} cache-r {}", u.msgs, k(u.input), k(u.output), k(u.cache_r))),
            ])
        }).collect();
        f.render_widget(Paragraph::new(models).block(block("BY MODEL")), rows[3]);
    }
}
