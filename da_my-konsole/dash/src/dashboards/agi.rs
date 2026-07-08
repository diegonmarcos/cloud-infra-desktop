// AGI — Claude Code usage analytics (cloud-terminal AGI port). Scans
// ~/.claude/projects/**/*.jsonl transcripts for token usage.
use std::collections::BTreeMap;

use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::frame::Dashboard;
use crate::ui::block;
use super::sh;

#[derive(Default, Clone)]
struct Usage { input: u64, output: u64, cache_r: u64, cache_w: u64, msgs: u64 }

pub struct Agi {
    total: Usage,
    by_model: BTreeMap<String, Usage>,
    sessions: usize,
}

impl Agi {
    pub fn new() -> Self { Agi { total: Usage::default(), by_model: BTreeMap::new(), sessions: 0 } }
}

fn add(u: &mut Usage, usage: &serde_json::Value) {
    u.input += usage.get("input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
    u.output += usage.get("output_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
    u.cache_r += usage.get("cache_read_input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
    u.cache_w += usage.get("cache_creation_input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
    u.msgs += 1;
}

impl Dashboard for Agi {
    fn title(&self) -> String { "🤖 agi".into() }
    fn tick_ms(&self) -> u64 { 8000 }

    fn update(&mut self) {
        self.total = Usage::default();
        self.by_model.clear();
        self.sessions = 0;
        let files = sh("find $HOME/.claude/projects -name '*.jsonl' -mtime -30 2>/dev/null");
        for path in files.lines() {
            self.sessions += 1;
            let Ok(txt) = std::fs::read_to_string(path) else { continue };
            for line in txt.lines() {
                let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
                let Some(usage) = v.pointer("/message/usage") else { continue };
                add(&mut self.total, usage);
                let model = v.pointer("/message/model").and_then(|m| m.as_str()).unwrap_or("?").to_string();
                add(self.by_model.entry(model).or_default(), usage);
            }
        }
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        let rows = Layout::vertical([Constraint::Length(4), Constraint::Min(0)]).split(area);
        let t = &self.total;
        let k = |n: u64| if n >= 1_000_000 { format!("{:.1}M", n as f64 / 1e6) } else { format!("{:.0}K", n as f64 / 1e3) };
        let tiles = vec![
            Line::from(vec![
                Span::styled(format!("  sessions {}  ", self.sessions), Style::default().fg(Color::Cyan)),
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

        let models: Vec<Line> = self.by_model.iter().map(|(m, u)| {
            let short: String = m.rsplit('/').next().unwrap_or(m).chars().take(28).collect();
            Line::from(vec![
                Span::styled(format!("{short:<28} "), Style::default().fg(Color::Cyan)),
                Span::raw(format!("msgs {:<6} in {:<7} out {:<7} cache-r {}", u.msgs, k(u.input), k(u.output), k(u.cache_r))),
            ])
        }).collect();
        f.render_widget(Paragraph::new(models).block(block("BY MODEL")), rows[1]);
    }
}
