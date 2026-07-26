// AGI — Claude Code usage + cost analytics (cloud-terminal AGI port). Scans
// ~/.claude/projects/**/*.jsonl transcripts for token usage and prices them
// against src/data/model-pricing.json (synced to $HOME/.local/share/my-konsole/).
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
struct SessionInfo { name: String, age_secs: u64, msgs: u64, tokens: u64, cost: f64 }

struct ModelRate { input: f64, output: f64 }

struct Pricing { default: ModelRate, models: Vec<(String, ModelRate)>, cache_w_mult: f64, cache_r_mult: f64 }

impl Pricing {
    fn load() -> Self {
        let txt = sh("cat $HOME/.local/share/my-konsole/model-pricing.json 2>/dev/null");
        let v: serde_json::Value = serde_json::from_str(&txt).unwrap_or(serde_json::Value::Null);
        let rate = |o: &serde_json::Value| ModelRate {
            input: o.get("input").and_then(|x| x.as_f64()).unwrap_or(3.0),
            output: o.get("output").and_then(|x| x.as_f64()).unwrap_or(15.0),
        };
        let default = v.get("default").map(rate).unwrap_or(ModelRate { input: 3.0, output: 15.0 });
        let models = v.get("models").and_then(|m| m.as_array()).map(|arr| {
            arr.iter().filter_map(|m| {
                let name = m.get("match").and_then(|x| x.as_str())?.to_string();
                Some((name, rate(m)))
            }).collect()
        }).unwrap_or_default();
        Pricing {
            default,
            models,
            cache_w_mult: v.get("cache_write_multiplier").and_then(|x| x.as_f64()).unwrap_or(1.25),
            cache_r_mult: v.get("cache_read_multiplier").and_then(|x| x.as_f64()).unwrap_or(0.1),
        }
    }

    fn rate_for(&self, model: &str) -> &ModelRate {
        self.models.iter().find(|(m, _)| model.contains(m.as_str())).map(|(_, r)| r).unwrap_or(&self.default)
    }

    fn cost(&self, model: &str, u: &Usage) -> f64 {
        let r = self.rate_for(model);
        let cache_w_rate = r.input * self.cache_w_mult;
        let cache_r_rate = r.input * self.cache_r_mult;
        (u.input as f64 * r.input
            + u.output as f64 * r.output
            + u.cache_w as f64 * cache_w_rate
            + u.cache_r as f64 * cache_r_rate) / 1_000_000.0
    }
}

pub struct Agi {
    total: Usage,
    total_cost: f64,
    by_model: BTreeMap<String, Usage>,
    by_model_cost: BTreeMap<String, f64>,
    sessions: usize,
    recent: Vec<SessionInfo>,   // sorted newest-first
    active: usize,
    by_day: [u64; 7],           // tokens, index 0 = today
    cost_by_day: [f64; 7],
    by_project_cost: Vec<(String, f64)>, // sorted desc, top 8
}

impl Agi {
    pub fn new() -> Self {
        Agi {
            total: Usage::default(), total_cost: 0.0,
            by_model: BTreeMap::new(), by_model_cost: BTreeMap::new(),
            sessions: 0, recent: Vec::new(), active: 0,
            by_day: [0; 7], cost_by_day: [0.0; 7], by_project_cost: Vec::new(),
        }
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
        let pricing = Pricing::load();
        self.total = Usage::default();
        self.total_cost = 0.0;
        self.by_model.clear();
        self.by_model_cost.clear();
        self.sessions = 0;
        self.active = 0;
        self.by_day = [0; 7];
        self.cost_by_day = [0.0; 7];
        let mut project_cost: BTreeMap<String, f64> = BTreeMap::new();
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
            let mut s_cost = 0.0f64;
            for line in txt.lines() {
                let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
                let Some(usage) = v.pointer("/message/usage") else { continue };
                let model = v.pointer("/message/model").and_then(|m| m.as_str()).unwrap_or("?").to_string();
                let mut one = Usage::default();
                add(&mut one, usage);
                add(&mut self.total, usage);
                add(self.by_model.entry(model.clone()).or_default(), usage);
                let c = pricing.cost(&model, &one);
                self.total_cost += c;
                *self.by_model_cost.entry(model).or_default() += c;
                self.cost_by_day[day] += c;
                s_cost += c;

                let tin = usage.get("input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
                let tout = usage.get("output_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
                s_msgs += 1;
                s_tokens += tin + tout;
                self.by_day[day] += tin + tout;
            }
            let name: String = std::path::Path::new(path)
                .parent().and_then(|p| p.file_name()).and_then(|s| s.to_str())
                .unwrap_or("?").chars().take(32).collect();
            *project_cost.entry(name.clone()).or_default() += s_cost;
            sessions.push(SessionInfo { name, age_secs: age, msgs: s_msgs, tokens: s_tokens, cost: s_cost });
        }
        sessions.sort_by_key(|s| s.age_secs);
        sessions.truncate(15);
        self.recent = sessions;

        let mut projects: Vec<(String, f64)> = project_cost.into_iter().collect();
        projects.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        projects.truncate(8);
        self.by_project_cost = projects;
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        let rows = Layout::vertical([
            Constraint::Length(4),
            Constraint::Length(9),
            Constraint::Min(6),
            Constraint::Length(9),
            Constraint::Length(10),
        ]).split(area);
        let t = &self.total;
        let k = |n: u64| if n >= 1_000_000 { format!("{:.1}M", n as f64 / 1e6) } else { format!("{:.0}K", n as f64 / 1e3) };
        let cache_hit_pct = if t.input + t.cache_r == 0 { 0.0 } else { t.cache_r as f64 * 100.0 / (t.input + t.cache_r) as f64 };
        let today_cost = self.cost_by_day[0];
        let week_cost: f64 = self.cost_by_day.iter().take(7).sum();
        let tiles = vec![
            Line::from(vec![
                Span::styled(format!("  sessions {} ", self.sessions), Style::default().fg(Color::Cyan)),
                Span::styled(format!("  active now {} ", self.active), Style::default().fg(Color::Green)),
                Span::styled(format!("  messages {}  ", t.msgs), Style::default().fg(Color::Gray)),
                Span::styled(format!("  cache-hit {:.0}%  ", cache_hit_pct), Style::default().fg(Color::Blue)),
            ]),
            Line::from(vec![
                Span::styled(format!("  in {}  ", k(t.input)), Style::default().fg(Color::Green)),
                Span::styled(format!("  out {}  ", k(t.output)), Style::default().fg(Color::Yellow)),
                Span::styled(format!("  cache-r {}  ", k(t.cache_r)), Style::default().fg(Color::Blue)),
                Span::styled(format!("  cache-w {}  ", k(t.cache_w)), Style::default().fg(Color::Magenta)),
            ]),
            Line::from(vec![
                Span::styled(format!("  ${:.2} today  ", today_cost), Style::default().fg(Color::Green)),
                Span::styled(format!("  ${:.2} 7d  ", week_cost), Style::default().fg(Color::Yellow)),
                Span::styled(format!("  ${:.2} 30d  ", self.total_cost), Style::default().fg(Color::Red)),
            ]),
        ];
        f.render_widget(Paragraph::new(tiles).block(block("TOTAL + COST (last 30d)")), rows[0]);

        let day_names = ["Today", "Yesterday", "2d ago", "3d ago", "4d ago", "5d ago", "6d ago"];
        let max_tok = self.by_day.iter().copied().max().unwrap_or(1).max(1);
        let days: Vec<Line> = (0..7).map(|i| {
            let toks = self.by_day[i];
            let bar_len = (toks * 30 / max_tok) as usize;
            Line::from(vec![
                Span::styled(format!("{:<10}", day_names[i]), Style::default().fg(Color::Gray)),
                Span::styled("█".repeat(bar_len), Style::default().fg(Color::Cyan)),
                Span::raw(format!(" {:<7}", k(toks))),
                Span::styled(format!("${:.2}", self.cost_by_day[i]), Style::default().fg(Color::Green)),
            ])
        }).collect();
        f.render_widget(Paragraph::new(days).block(block("TOKENS + COST / DAY (last 7d)")), rows[1]);

        let sessions: Vec<Line> = self.recent.iter().map(|s| Line::from(vec![
            Span::styled(format!("{:<32} ", s.name), Style::default().fg(if s.age_secs <= ACTIVE_SECS { Color::Green } else { Color::Cyan })),
            Span::raw(format!("{:<10} msgs {:<5} tokens {:<8} ", age_label(s.age_secs), s.msgs, k(s.tokens))),
            Span::styled(format!("${:.3}", s.cost), Style::default().fg(Color::Green)),
        ])).collect();
        f.render_widget(Paragraph::new(sessions).block(block("LAST 15 SESSIONS")), rows[2]);

        let models: Vec<Line> = self.by_model.iter().map(|(m, u)| {
            let short: String = m.rsplit('/').next().unwrap_or(m).chars().take(24).collect();
            let cost = self.by_model_cost.get(m).copied().unwrap_or(0.0);
            Line::from(vec![
                Span::styled(format!("{short:<24} "), Style::default().fg(Color::Cyan)),
                Span::raw(format!("msgs {:<6} in {:<7} out {:<7} cache-r {:<7} ", u.msgs, k(u.input), k(u.output), k(u.cache_r))),
                Span::styled(format!("${:.3}", cost), Style::default().fg(Color::Green)),
            ])
        }).collect();
        f.render_widget(Paragraph::new(models).block(block("BY MODEL + COST")), rows[3]);

        let max_pcost = self.by_project_cost.iter().map(|(_, c)| *c).fold(0.0, f64::max).max(0.001);
        let projects: Vec<Line> = self.by_project_cost.iter().map(|(name, cost)| {
            let bar_len = ((*cost / max_pcost) * 30.0) as usize;
            Line::from(vec![
                Span::styled(format!("{:<32} ", name), Style::default().fg(Color::Cyan)),
                Span::styled("█".repeat(bar_len), Style::default().fg(Color::Magenta)),
                Span::styled(format!(" ${:.3}", cost), Style::default().fg(Color::Green)),
            ])
        }).collect();
        f.render_widget(Paragraph::new(projects).block(block("TOP PROJECTS BY COST (30d)")), rows[4]);
    }
}
