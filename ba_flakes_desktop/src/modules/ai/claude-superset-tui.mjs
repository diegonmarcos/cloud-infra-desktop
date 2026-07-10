#!/usr/bin/env node
// claude-superset-tui — full-screen TUI to compose a `claude-superset` launch.
// No npm deps (node:readline raw-mode + ANSI). Endpoints come from the env
// (CAS_PROXY / CAS_API / CAS_DASHBOARD / CAS_MCP_* …) injected by the Nix
// wrapper from the data-driven claude-superset.json — nothing hardcoded.
//
// A REAL form, not a text menu:
//   ↑/↓  move between fields      Space  toggle / select
//   ←/→  change value (level, N)  Enter  activate LAUNCH
//   q    quit
//
//   ◉/◯  selection boxes (pick ONE): face, restore mode
//   [x]/[ ]  check boxes (toggles): headroom, ponytail
//
// Launching only happens when YOU move to LAUNCH and press Enter.
import readline from "node:readline";
import { spawn, spawnSync } from "node:child_process";

const EP = {
  proxy:     process.env.CAS_PROXY     || "http://10.0.0.6:8789",
  dashboard: process.env.CAS_DASHBOARD || "http://10.0.0.6:8788/dashboard",
  compress:  process.env.CAS_COMPRESS  || "http://10.0.0.6:8788",
};
const SELF = "claude-superset";
const RESTORE_PRESETS = { count: [1, 3, 5, 10, 20, 50], hours: [1, 4, 8, 24, 72, 168] };

const C = {
  r: "\x1b[0m", b: "\x1b[1m", dim: "\x1b[2m", inv: "\x1b[7m",
  g: "\x1b[32m", y: "\x1b[33m", red: "\x1b[31m", cy: "\x1b[36m", mag: "\x1b[35m",
};

// ── selection state ───────────────────────────────────────────────────────
const st = {
  face: "remote",      // remote | local | claude   (selection box)
  headroom: true,      // checkbox
  ponytail: true,      // checkbox
  ponyLevel: "full",   // lite | full | ultra        (← / → cycles)
  restore: "off",      // off | count | hours         (selection box)
  restoreN: 5,         // ← / → adjusts on presets
};
const PONY_LEVELS = ["lite", "full", "ultra"];

// Compose the argv exactly like the shell wrapper's grammar.
function selArgs() {
  if (st.face === "claude") return ["claude"];
  const a = [st.face];
  if (!st.headroom) a.push("headroom", "off");
  a.push("ponytail", st.ponytail ? st.ponyLevel : "off");
  if (st.restore === "count") a.push("restore", String(st.restoreN));
  if (st.restore === "hours") a.push("restore-hours", String(st.restoreN));
  return a;
}

// ── focusable rows (rebuilt each render; disabled fields drop out) ──────────
function buildRows() {
  const rows = [];
  rows.push({ t: "head", text: "FACE  — pick one" });
  rows.push({ t: "radio", grp: "face", val: "remote", label: "remote", note: "route via the WG compression proxy" });
  rows.push({ t: "radio", grp: "face", val: "local",  label: "local",  note: "run the container on THIS host" });
  rows.push({ t: "radio", grp: "face", val: "claude", label: "claude", note: "plain — no proxy / plugins / restore" });

  if (st.face !== "claude") {
    rows.push({ t: "gap" });
    rows.push({ t: "head", text: "PLUGINS  — toggle" });
    rows.push({ t: "check", key: "headroom", label: "headroom", note: "compression proxy (ANTHROPIC_BASE_URL)" });
    rows.push({ t: "checklevel", key: "ponytail", label: "ponytail", note: "← / → level" });

    rows.push({ t: "gap" });
    rows.push({ t: "head", text: "RESTORE SESSIONS  — pick one" });
    rows.push({ t: "radio", grp: "restore", val: "off",   label: "off",   note: "fresh session" });
    rows.push({ t: "radio", grp: "restore", val: "count", label: "count", note: "reopen last N sessions" });
    rows.push({ t: "radio", grp: "restore", val: "hours", label: "hours", note: "reopen sessions from last N hours" });
    if (st.restore !== "off")
      rows.push({ t: "number", key: "restoreN", label: "N", note: "← / →" });
  }

  rows.push({ t: "gap" });
  rows.push({ t: "action", key: "launch" });
  rows.push({ t: "action", key: "quit" });
  return rows;
}
const isFocusable = (row) => ["radio", "check", "checklevel", "number", "action"].includes(row.t);

let rows = buildRows();
let focus = 0; // index into focusable rows only
function focusables() { return rows.map((r, i) => (isFocusable(r) ? i : -1)).filter((i) => i >= 0); }

let proxyUp = null, saved = null;
async function probe() {
  try {
    const c = new AbortController(); const t = setTimeout(() => c.abort(), 1500);
    const r = await fetch(`${EP.proxy.replace(/\/$/, "")}/readyz`, { signal: c.signal }).finally(() => clearTimeout(t));
    proxyUp = r.ok;
  } catch { proxyUp = false; }
  try {
    const c = new AbortController(); const t = setTimeout(() => c.abort(), 1500);
    const r = await fetch(`${EP.compress.replace(/\/$/, "")}/stats`, { signal: c.signal }).finally(() => clearTimeout(t));
    const j = await r.json(); saved = Number(j.tokens_saved || 0);
  } catch { saved = null; }
}

// ── render ──────────────────────────────────────────────────────────────────
function render() {
  rows = buildRows();
  const fl = focusables();
  if (focus >= fl.length) focus = fl.length - 1;
  if (focus < 0) focus = 0;
  const focusedRowIdx = fl[focus];

  const out = [];
  out.push("\x1b[2J\x1b[H"); // clear + home
  out.push(`${C.b}${C.cy}  claude-superset${C.r}  ${C.dim}— compose a launch${C.r}\n`);
  const pstat = proxyUp == null ? `${C.dim}…${C.r}` : proxyUp ? `${C.g}● proxy up${C.r}` : `${C.red}○ proxy down${C.r}`;
  const sstat = saved == null ? "" : `  ${C.dim}·${C.r} ${C.y}${saved.toLocaleString()}${C.r} ${C.dim}tok saved${C.r}`;
  out.push(`  ${pstat}${sstat}\n`);
  out.push("\n");

  rows.forEach((row, i) => {
    const foc = i === focusedRowIdx;
    const cur = foc ? `${C.cy}${C.b}❯${C.r} ` : "  ";
    const hl = (s) => (foc ? `${C.inv}${s}${C.r}` : s);
    if (row.t === "head") { out.push(`   ${C.dim}${row.text}${C.r}\n`); return; }
    if (row.t === "gap") { out.push("\n"); return; }
    let body = "";
    if (row.t === "radio") {
      const on = st[row.grp] === row.val;
      const box = on ? `${C.g}◉${C.r}` : `${C.dim}◯${C.r}`;
      body = `${box} ${hl(row.label.padEnd(8))} ${C.dim}${row.note}${C.r}`;
    } else if (row.t === "check") {
      const on = st[row.key];
      const box = on ? `${C.g}[x]${C.r}` : `${C.dim}[ ]${C.r}`;
      body = `${box} ${hl(row.label.padEnd(8))} ${C.dim}${row.note}${C.r}`;
    } else if (row.t === "checklevel") {
      const on = st[row.key];
      const box = on ? `${C.g}[x]${C.r}` : `${C.dim}[ ]${C.r}`;
      const lvl = on ? `${C.mag}‹ ${st.ponyLevel} ›${C.r}` : `${C.dim}(off)${C.r}`;
      body = `${box} ${hl(row.label.padEnd(8))} ${lvl}  ${C.dim}${row.note}${C.r}`;
    } else if (row.t === "number") {
      body = `    ${hl(row.label)} ${C.mag}‹ ${st.restoreN} ›${C.r}  ${C.dim}${row.note}${C.r}`;
    } else if (row.t === "action") {
      const label = row.key === "launch" ? " LAUNCH " : " Quit ";
      const col = row.key === "launch" ? C.g : C.dim;
      body = foc ? `${C.inv}${col}${label}${C.r}` : `${col}[${label.trim()}]${C.r}`;
      if (row.key === "launch") body += `   ${C.cy}${SELF} ${selArgs().join(" ")}${C.r}`;
    }
    out.push(`${cur}${body}\n`);
  });

  out.push("\n");
  out.push(`  ${C.dim}↑/↓ move · Space select/toggle · ←/→ change · Enter launch · q quit${C.r}\n`);
  process.stdout.write(out.join(""));
}

// ── input ─────────────────────────────────────────────────────────────────
function activate(row) {
  if (row.t === "radio") st[row.grp] = row.val;
  else if (row.t === "check" || row.t === "checklevel") st[row.key] = !st[row.key];
}
function adjust(row, dir) {
  if (row.t === "checklevel" && st.ponytail) {
    const i = PONY_LEVELS.indexOf(st.ponyLevel);
    st.ponyLevel = PONY_LEVELS[(i + dir + PONY_LEVELS.length) % PONY_LEVELS.length];
  } else if (row.t === "number") {
    const p = RESTORE_PRESETS[st.restore] || [];
    const i = Math.max(0, p.indexOf(st.restoreN));
    st.restoreN = p[Math.min(p.length - 1, Math.max(0, i + dir))];
  } else if (row.t === "radio") {
    // ←/→ also cycles within a selection group for convenience
    const opts = rows.filter((r) => r.t === "radio" && r.grp === row.grp).map((r) => r.val);
    const i = opts.indexOf(st[row.grp]);
    st[row.grp] = opts[(i + dir + opts.length) % opts.length];
  }
}

function teardown() {
  if (process.stdin.isTTY) process.stdin.setRawMode(false);
  process.stdout.write("\x1b[?25h"); // show cursor
}

function launch() {
  teardown();
  process.stdout.write("\x1b[2J\x1b[H");
  const child = spawn(SELF, selArgs(), { stdio: "inherit" });
  child.on("exit", (c) => process.exit(c ?? 0));
  child.on("error", () => { console.log(`${SELF} not found on PATH`); process.exit(1); });
}

async function main() {
  if (!process.stdin.isTTY) {
    console.log(`claude-superset TUI needs a terminal. Would launch: ${SELF} ${selArgs().join(" ")}`);
    process.exit(0);
  }
  process.stdout.write("\x1b[?25l"); // hide cursor
  render();
  probe().then(render);

  readline.emitKeypressEvents(process.stdin);
  process.stdin.setRawMode(true);
  process.stdin.on("keypress", (str, key) => {
    const fl = focusables();
    const row = rows[fl[focus]];
    const name = key?.name;
    if (name === "q" || (key?.ctrl && name === "c")) { teardown(); process.exit(0); }
    else if (name === "up" || name === "k") focus = (focus - 1 + fl.length) % fl.length;
    else if (name === "down" || name === "j") focus = (focus + 1) % fl.length;
    else if (name === "left" || name === "h") adjust(row, -1);
    else if (name === "right" || name === "l") adjust(row, 1);
    else if (name === "space") { row.t === "action" ? (row.key === "launch" ? launch() : (teardown(), process.exit(0))) : activate(row); }
    else if (name === "return") {
      if (row.t === "action") { row.key === "launch" ? launch() : (teardown(), process.exit(0)); }
      else if (row.t === "radio" || row.t === "check" || row.t === "checklevel") activate(row);
    } else return;
    render();
  });
}
main();
