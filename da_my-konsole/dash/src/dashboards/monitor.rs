// Monitor — btop-style live system dashboard (cloud-terminal MONITOR port).
// CPU/mem/procs from sysinfo; net from /proc/net/dev deltas; disks from df.
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Cell, Gauge, Row, Sparkline, Table};
use ratatui::Frame;
use sysinfo::System;

use crate::frame::Dashboard;
use crate::ui::{block, fmt_bytes, pct_color};
use super::sh;

pub struct Monitor {
    sys: System,
    host: String,
    kernel: String,
    cpu: u64,
    cpu_hist: Vec<u64>,
    cores: Vec<u64>,
    mem_used: u64,
    mem_total: u64,
    swap_used: u64,
    swap_total: u64,
    prev_rx: u64,
    prev_tx: u64,
    rx_rate: u64,
    tx_rate: u64,
    rx_hist: Vec<u64>,
    tx_hist: Vec<u64>,
    disks: Vec<(String, u64, u64)>, // mount, used, total
    procs: Vec<(u32, String, f32, u64)>, // pid, name, cpu%, mem bytes
}

impl Monitor {
    pub fn new() -> Self {
        let sys = System::new_all();
        Monitor {
            sys,
            host: System::host_name().unwrap_or_default(),
            kernel: System::kernel_version().unwrap_or_default(),
            cpu: 0, cpu_hist: vec![0; 120], cores: vec![],
            mem_used: 0, mem_total: 1, swap_used: 0, swap_total: 0,
            prev_rx: 0, prev_tx: 0, rx_rate: 0, tx_rate: 0,
            rx_hist: vec![0; 120], tx_hist: vec![0; 120],
            disks: vec![], procs: vec![],
        }
    }
}

fn push(v: &mut Vec<u64>, x: u64, cap: usize) {
    v.push(x);
    if v.len() > cap { v.remove(0); }
}

// Sum rx/tx bytes across real interfaces from /proc/net/dev.
fn net_totals() -> (u64, u64) {
    let (mut rx, mut tx) = (0u64, 0u64);
    for line in sh("cat /proc/net/dev").lines().skip(2) {
        let Some((iface, rest)) = line.split_once(':') else { continue };
        let iface = iface.trim();
        if iface == "lo" || iface.starts_with("veth") || iface.starts_with("docker") || iface.starts_with("br-") { continue; }
        let f: Vec<u64> = rest.split_whitespace().filter_map(|x| x.parse().ok()).collect();
        if f.len() >= 9 { rx += f[0]; tx += f[8]; }
    }
    (rx, tx)
}

impl Dashboard for Monitor {
    fn title(&self) -> String { "📊 monitor".into() }
    fn tick_ms(&self) -> u64 { 1000 }

    fn update(&mut self) {
        self.sys.refresh_all();
        self.cpu = self.sys.global_cpu_usage() as u64;
        push(&mut self.cpu_hist, self.cpu, 120);
        self.cores = self.sys.cpus().iter().map(|c| c.cpu_usage() as u64).collect();
        self.mem_used = self.sys.used_memory();
        self.mem_total = self.sys.total_memory().max(1);
        self.swap_used = self.sys.used_swap();
        self.swap_total = self.sys.total_swap();

        let (rx, tx) = net_totals();
        if self.prev_rx > 0 { self.rx_rate = rx.saturating_sub(self.prev_rx); }
        if self.prev_tx > 0 { self.tx_rate = tx.saturating_sub(self.prev_tx); }
        self.prev_rx = rx; self.prev_tx = tx;
        push(&mut self.rx_hist, self.rx_rate / 1024, 120);
        push(&mut self.tx_hist, self.tx_rate / 1024, 120);

        self.disks = sh("df -B1 --output=target,used,size -x tmpfs -x devtmpfs -x overlay 2>/dev/null | tail -n +2")
            .lines()
            .filter_map(|l| {
                let c: Vec<&str> = l.split_whitespace().collect();
                if c.len() == 3 {
                    Some((c[0].to_string(), c[1].parse().unwrap_or(0), c[2].parse().unwrap_or(1)))
                } else { None }
            })
            .collect();

        let mut p: Vec<_> = self.sys.processes().iter()
            .map(|(pid, pr)| (pid.as_u32(), pr.name().to_string_lossy().to_string(), pr.cpu_usage(), pr.memory()))
            .collect();
        p.sort_by(|a, b| b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal));
        p.truncate(18);
        self.procs = p;
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        let rows = Layout::vertical([
            Constraint::Length(1),
            Constraint::Length(8),
            Constraint::Length(7),
            Constraint::Min(6),
        ]).split(area);

        // header
        f.render_widget(
            Line::from(vec![
                Span::styled(format!(" {} ", self.host), Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)),
                Span::styled(format!("· {} · {} cores", self.kernel, self.cores.len()), Style::default().fg(Color::DarkGray)),
            ]),
            rows[0],
        );

        // row1: CPU | MEM
        let r1 = Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)]).split(rows[1]);
        let cpu_in = block("CPU").inner(r1[0]);
        f.render_widget(block("CPU"), r1[0]);
        let cpu_rows = Layout::vertical([Constraint::Length(1), Constraint::Min(1)]).split(cpu_in);
        f.render_widget(Gauge::default().ratio((self.cpu as f64 / 100.0).min(1.0))
            .gauge_style(Style::default().fg(pct_color(self.cpu as f64)))
            .label(format!("{}%", self.cpu)), cpu_rows[0]);
        f.render_widget(Sparkline::default().data(&self.cpu_hist).max(100)
            .style(Style::default().fg(Color::Cyan)), cpu_rows[1]);

        let mem_in = block("MEMORY").inner(r1[1]);
        f.render_widget(block("MEMORY"), r1[1]);
        let mem_rows = Layout::vertical([Constraint::Length(1), Constraint::Length(1), Constraint::Min(0)]).split(mem_in);
        let memp = self.mem_used as f64 / self.mem_total as f64 * 100.0;
        f.render_widget(Gauge::default().ratio((memp / 100.0).min(1.0))
            .gauge_style(Style::default().fg(pct_color(memp)))
            .label(format!("RAM {}/{}", fmt_bytes(self.mem_used), fmt_bytes(self.mem_total))), mem_rows[0]);
        if self.swap_total > 0 {
            let sp = self.swap_used as f64 / self.swap_total as f64 * 100.0;
            f.render_widget(Gauge::default().ratio((sp / 100.0).min(1.0))
                .gauge_style(Style::default().fg(Color::Magenta))
                .label(format!("SWAP {}/{}", fmt_bytes(self.swap_used), fmt_bytes(self.swap_total))), mem_rows[1]);
        }

        // row2: CORES | NET
        let r2 = Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)]).split(rows[2]);
        let core_in = block("CORES").inner(r2[0]);
        f.render_widget(block("CORES"), r2[0]);
        let core_lines: Vec<Line> = self.cores.iter().enumerate().map(|(i, &c)| {
            let filled = (c as usize * 20 / 100).min(20);
            Line::from(vec![
                Span::styled(format!("{i:2} "), Style::default().fg(Color::DarkGray)),
                Span::styled("█".repeat(filled), Style::default().fg(pct_color(c as f64))),
                Span::styled("░".repeat(20 - filled), Style::default().fg(Color::DarkGray)),
                Span::raw(format!(" {c:>3}%")),
            ])
        }).collect();
        f.render_widget(ratatui::widgets::Paragraph::new(core_lines), core_in);

        let net_in = block("NETWORK").inner(r2[1]);
        f.render_widget(block("NETWORK"), r2[1]);
        let net_rows = Layout::vertical([Constraint::Length(1), Constraint::Min(1), Constraint::Length(1), Constraint::Min(1)]).split(net_in);
        f.render_widget(Line::from(Span::styled(format!("▼ {}/s", fmt_bytes(self.rx_rate)), Style::default().fg(Color::Green))), net_rows[0]);
        f.render_widget(Sparkline::default().data(&self.rx_hist).style(Style::default().fg(Color::Green)), net_rows[1]);
        f.render_widget(Line::from(Span::styled(format!("▲ {}/s", fmt_bytes(self.tx_rate)), Style::default().fg(Color::Magenta))), net_rows[2]);
        f.render_widget(Sparkline::default().data(&self.tx_hist).style(Style::default().fg(Color::Magenta)), net_rows[3]);

        // row3: DISKS | PROCESSES
        let r3 = Layout::horizontal([Constraint::Percentage(35), Constraint::Percentage(65)]).split(rows[3]);
        let disk_in = block("DISKS").inner(r3[0]);
        f.render_widget(block("DISKS"), r3[0]);
        let disk_lines: Vec<Line> = self.disks.iter().map(|(m, u, t)| {
            let p = *u as f64 / (*t).max(1) as f64 * 100.0;
            let filled = (p as usize * 14 / 100).min(14);
            Line::from(vec![
                Span::styled(format!("{:<10} ", m.chars().take(10).collect::<String>()), Style::default().fg(Color::Gray)),
                Span::styled("█".repeat(filled), Style::default().fg(pct_color(p))),
                Span::styled("░".repeat(14 - filled), Style::default().fg(Color::DarkGray)),
                Span::raw(format!(" {:>3.0}%", p)),
            ])
        }).collect();
        f.render_widget(ratatui::widgets::Paragraph::new(disk_lines), disk_in);

        let proc_rows: Vec<Row> = self.procs.iter().map(|(pid, name, cpu, mem)| {
            Row::new(vec![
                Cell::from(pid.to_string()),
                Cell::from(name.chars().take(20).collect::<String>()),
                Cell::from(format!("{cpu:>4.1}")).style(Style::default().fg(pct_color(*cpu as f64))),
                Cell::from(fmt_bytes(*mem)),
            ])
        }).collect();
        let ptable = Table::new(proc_rows, [Constraint::Length(7), Constraint::Min(10), Constraint::Length(6), Constraint::Length(8)])
            .header(Row::new(vec!["PID", "NAME", "CPU%", "MEM"]).style(Style::default().fg(Color::Cyan)))
            .block(block("PROCESSES"));
        f.render_widget(ptable, r3[1]);
    }
}
