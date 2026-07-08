// Shared UI helpers for the dashboards.
use ratatui::style::{Color, Style};
use ratatui::widgets::{Block, Borders};

pub const ACCENT: Color = Color::Cyan;

pub fn block(title: &str) -> Block<'static> {
    Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::DarkGray))
        .title(format!(" {title} "))
        .title_style(Style::default().fg(ACCENT))
}

pub fn fmt_bytes(b: u64) -> String {
    const U: [&str; 6] = ["B", "K", "M", "G", "T", "P"];
    let mut v = b as f64;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 { format!("{b}{}", U[i]) } else { format!("{v:.1}{}", U[i]) }
}

pub fn fmt_kb(kb: u64) -> String {
    fmt_bytes(kb.saturating_mul(1024))
}

// green < 60 < yellow < 85 < red
pub fn pct_color(p: f64) -> Color {
    if p >= 85.0 { Color::Red } else if p >= 60.0 { Color::Yellow } else { Color::Green }
}

pub fn dot(ok: bool) -> ratatui::text::Span<'static> {
    if ok {
        ratatui::text::Span::styled("●", Style::default().fg(Color::Green))
    } else {
        ratatui::text::Span::styled("●", Style::default().fg(Color::Red))
    }
}
