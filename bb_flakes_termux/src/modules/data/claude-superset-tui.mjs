#!/usr/bin/env node
// claude-superset-tui — full-screen TUI to compose a `claude-superset` launch.
// No npm deps (node:readline raw-mode + ANSI). Endpoints come from the env
// (CAS_PROXY / CAS_API / CAS_OLLAMA / CAS_COMPRESS / CAS_DASHBOARD / CAS_MCP_* /
//  CAS_ANTHROPIC) injected by the Nix wrapper from claude-superset.json.
//
// A REAL form:
//   ↑/↓  move between fields          Space  toggle / select
//   ←/→  change value (level, N)      0-9    TYPE the restore count/hours
//   Enter  launch                     r      refresh status      q  quit
//
//   ◉/◯  selection boxes (pick ONE): face, restore mode
//   [x]/[ ]  check boxes (toggles): headroom, ponytail
//
// Launching only happens when YOU move to LAUNCH and press Enter.
import readline from "node:readline";
import { spawn } from "node:child_process";

const EP = {
  proxy:     process.env.CAS_PROXY     || "http://10.0.0.6:8789",
  api:       process.env.CAS_API       || "http://10.0.0.6:3117",
  ollama:    process.env.CAS_OLLAMA    || "http://10.0.0.6:11436",
  compress:  process.env.CAS_COMPRESS  || "http://10.0.0.6:8788",
  dashboard: process.env.CAS_DASHBOARD || "http://10.0.0.6:8788/dashboard",
  anthropic: process.env.CAS_ANTHROPIC || "https://api.anthropic.com",
  mcps: {
    c3_infra:   process.env.CAS_MCP_C3_INFRA   || "http://10.0.0.6:3100",
    c3_svc:     process.env.CAS_MCP_C3_SVC     || "http://10.0.0.6:3101",
    mattermost: process.env.CAS_MCP_MATTERMOST || "http://10.0.0.6:3102",
    mail:       process.env.CAS_MCP_MAIL       || "http://10.0.0.6:3103",
    gws:        process.env.CAS_MCP_GWS        || "http://10.0.0.6:3104",
    gp:         process.env.CAS_MCP_GP         || "http://10.0.0.6:3106",
  },
};
const SELF = "claude-superset";
const RESTORE_PRESETS = { count: [1, 3, 5, 10, 20, 50], hours: [1, 4, 8, 24, 72, 168] };
const PONY_LEVELS = ["lite", "full", "ultra"];

const C = {
  r: "\x1b[0m", b: "\x1b[1m", dim: "\x1b[2m", inv: "\x1b[7m",
  g: "\x1b[32m", y: "\x1b[33m", red: "\x1b[31m", cy: "\x1b[36m", mag: "\x1b[35m",
};

// ── selection state ───────────────────────────────────────────────────────
const st = {
  face: "remote", headroom: true, ponytail: true, ponyLevel: "full",
  restore: "off", restoreN: 5,
};
let numBuf = ""; // digits typed into the focused N field (empty = show restoreN)

function selArgs() {
  if (st.face === "claude") return ["claude"];
  const a = [st.face];
  if (!st.headroom) a.push("headroom", "off");
  a.push("ponytail", st.ponytail ? st.ponyLevel : "off");
  const n = String(Math.max(1, st.restoreN || 1));
  if (st.restore === "count") a.push("restore", n);
  if (st.restore === "hours") a.push("restore-hours", n);
  return a;
}

// ── health probes ───────────────────────────────────────────────────────────
const health = { proxy: null, api: null, ollama: null, compress: null, direct: null,
  c3_infra: null, c3_svc: null, mattermost: null, mail: null, gws: null, gp: null };
let saved = null, ratio = null;
async function probe1(url, path, anyStatus = false) {
  try {
    const c = new AbortController(); const t = setTimeout(() => c.abort(), 2000);
    const r = await fetch(`${url.replace(/\/$/, "")}${path}`, { signal: c.signal }).finally(() => clearTimeout(t));
    return anyStatus ? true : r.ok;
  } catch { return false; }
}
async function probeAll() {
  const [p, a, o, c, ci, cs, mm, ml, gw, gp, d] = await Promise.all([
    probe1(EP.proxy, "/readyz"), probe1(EP.api, "/health"), probe1(EP.ollama, "/api/version"),
    probe1(EP.compress, "/readyz"), probe1(EP.mcps.c3_infra, "/health"), probe1(EP.mcps.c3_svc, "/health"),
    probe1(EP.mcps.mattermost, "/health"), probe1(EP.mcps.mail, "/health"), probe1(EP.mcps.gws, "/health"),
    probe1(EP.mcps.gp, "/health"), probe1(EP.anthropic, "/v1/models", true),
  ]);
  Object.assign(health, { proxy: p, api: a, ollama: o, compress: c, c3_infra: ci, c3_svc: cs,
    mattermost: mm, mail: ml, gws: gw, gp, direct: d });
  try {
    const r = await fetch(`${EP.compress.replace(/\/$/, "")}/stats`, { signal: AbortSignal.timeout(2000) });
    const j = await r.json(); saved = Number(j.tokens_saved || 0); ratio = Number(j.lifetime_ratio || 0);
  } catch { saved = null; ratio = null; }
}
const dot = (v) => (v == null ? `${C.dim}…${C.r}` : v ? `${C.g}●${C.r}` : `${C.red}○${C.r}`);

// ── focusable rows ──────────────────────────────────────────────────────────
function buildRows() {
  const rows = [];
  rows.push({ t: "head", text: "FACE  — pick one" });
  rows.push({ t: "radio", grp: "face", val: "remote", label: "remote", note: "WG compression proxy" });
  rows.push({ t: "radio", grp: "face", val: "local",  label: "local",  note: "container on THIS host" });
  rows.push({ t: "radio", grp: "face", val: "claude", label: "claude", note: "plain — no proxy/plugins/restore" });
  if (st.face !== "claude") {
    rows.push({ t: "gap" }, { t: "head", text: "PLUGINS  — toggle" });
    rows.push({ t: "check", key: "headroom", label: "headroom", note: "compression proxy" });
    rows.push({ t: "checklevel", key: "ponytail", label: "ponytail", note: "← / → level" });
    rows.push({ t: "gap" }, { t: "head", text: "RESTORE SESSIONS  — pick one" });
    rows.push({ t: "radio", grp: "restore", val: "off",   label: "off",   note: "fresh session" });
    rows.push({ t: "radio", grp: "restore", val: "count", label: "count", note: "reopen last N sessions" });
    rows.push({ t: "radio", grp: "restore", val: "hours", label: "hours", note: "sessions from last N hours" });
    if (st.restore !== "off")
      rows.push({ t: "number", key: "restoreN", label: "N", note: "type digits, or ← / → presets" });
  }
  rows.push({ t: "gap" }, { t: "action", key: "launch" }, { t: "action", key: "quit" });
  return rows;
}
const isFocusable = (row) => ["radio", "check", "checklevel", "number", "action"].includes(row.t);
let rows = buildRows();
let focus = 0;
const focusables = () => rows.map((r, i) => (isFocusable(r) ? i : -1)).filter((i) => i >= 0);

// ── render ──────────────────────────────────────────────────────────────────
function render() {
  rows = buildRows();
  const fl = focusables();
  if (focus >= fl.length) focus = fl.length - 1;
  if (focus < 0) focus = 0;
  const focIdx = fl[focus];

  const o = ["\x1b[2J\x1b[H"];
  o.push(`${C.b}${C.cy}  claude-superset${C.r}  ${C.dim}— compose a launch${C.r}\n\n`);

  rows.forEach((row, i) => {
    const foc = i === focIdx;
    const cur = foc ? `${C.cy}${C.b}❯${C.r} ` : "  ";
    const hl = (s) => (foc ? `${C.inv}${s}${C.r}` : s);
    if (row.t === "head") return o.push(`   ${C.dim}${row.text}${C.r}\n`);
    if (row.t === "gap") return o.push("\n");
    let body = "";
    if (row.t === "radio") {
      const box = st[row.grp] === row.val ? `${C.g}◉${C.r}` : `${C.dim}◯${C.r}`;
      body = `${box} ${hl(row.label.padEnd(8))} ${C.dim}${row.note}${C.r}`;
    } else if (row.t === "check") {
      const box = st[row.key] ? `${C.g}[x]${C.r}` : `${C.dim}[ ]${C.r}`;
      body = `${box} ${hl(row.label.padEnd(8))} ${C.dim}${row.note}${C.r}`;
    } else if (row.t === "checklevel") {
      const box = st[row.key] ? `${C.g}[x]${C.r}` : `${C.dim}[ ]${C.r}`;
      const lvl = st[row.key] ? `${C.mag}‹ ${st.ponyLevel} ›${C.r}` : `${C.dim}(off)${C.r}`;
      body = `${box} ${hl(row.label.padEnd(8))} ${lvl}  ${C.dim}${row.note}${C.r}`;
    } else if (row.t === "number") {
      const shown = foc && numBuf !== "" ? numBuf : String(st.restoreN);
      const field = foc ? `${C.inv} ${shown}_ ${C.r}` : `${C.mag}‹ ${shown} ›${C.r}`;
      body = `    ${hl(row.label)} ${field}  ${C.dim}${row.note}${C.r}`;
    } else if (row.t === "action") {
      const label = row.key === "launch" ? " LAUNCH " : " Quit ";
      const col = row.key === "launch" ? C.g : C.dim;
      body = foc ? `${C.inv}${col}${label}${C.r}` : `${col}[${label.trim()}]${C.r}`;
      if (row.key === "launch") body += `   ${C.cy}${SELF} ${selArgs().join(" ")}${C.r}`;
    }
    o.push(`${cur}${body}\n`);
  });

  // ── STATUS panel ──────────────────────────────────────────────────────────
  o.push(`\n   ${C.dim}── STATUS ──────────────────────────────${C.r}\n`);
  o.push(`   ${dot(health.proxy)} proxy   ${dot(health.api)} api   ${dot(health.ollama)} ollama   ${dot(health.compress)} compress   ${dot(health.direct)} direct\n`);
  o.push(`   ${C.dim}MCP${C.r} ${dot(health.c3_infra)} c3-infra ${dot(health.c3_svc)} c3-svc ${dot(health.mattermost)} mm ${dot(health.mail)} mail ${dot(health.gws)} gws ${dot(health.gp)} gp\n`);
  if (saved != null)
    o.push(`   ${C.y}savings${C.r} ${C.b}${saved.toLocaleString()}${C.r} tok ${C.dim}(${(ratio * 100).toFixed(0)}%)${C.r}\n`);
  else
    o.push(`   ${C.dim}savings — compress face unreachable${C.r}\n`);

  o.push(`\n  ${C.dim}↑/↓ move · Space toggle/select · ←/→ change · 0-9 type N · Enter launch · r refresh · q quit${C.r}\n`);
  process.stdout.write(o.join(""));
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
    numBuf = "";
    const p = RESTORE_PRESETS[st.restore] || [];
    const i = Math.max(0, p.indexOf(st.restoreN));
    st.restoreN = p[Math.min(p.length - 1, Math.max(0, i + dir))];
  } else if (row.t === "radio") {
    const opts = rows.filter((r) => r.t === "radio" && r.grp === row.grp).map((r) => r.val);
    const i = opts.indexOf(st[row.grp]);
    st[row.grp] = opts[(i + dir + opts.length) % opts.length];
  }
}
function teardown() {
  if (process.stdin.isTTY) process.stdin.setRawMode(false);
  process.stdout.write("\x1b[?25h");
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
  process.stdout.write("\x1b[?25l");
  render();
  probeAll().then(render);

  readline.emitKeypressEvents(process.stdin);
  process.stdin.setRawMode(true);
  process.stdin.on("keypress", (str, key) => {
    const fl = focusables();
    const row = rows[fl[focus]];
    const name = key?.name;
    const onAction = (k) => (k === "launch" ? launch() : (teardown(), process.exit(0)));

    if (name === "q" || (key?.ctrl && name === "c")) return (teardown(), process.exit(0));
    if (name === "r") { probeAll().then(render); render(); return; }
    if (name === "up" || name === "k") { numBuf = ""; focus = (focus - 1 + fl.length) % fl.length; }
    else if (name === "down" || name === "j" || name === "tab") { numBuf = ""; focus = (focus + 1) % fl.length; }
    else if (name === "left") adjust(row, -1);
    else if (name === "right") adjust(row, 1);
    else if (row?.t === "number" && str && /^[0-9]$/.test(str)) {
      numBuf = (numBuf + str).slice(0, 4).replace(/^0+/, "") || "0";
      st.restoreN = Number(numBuf);
    }
    else if (row?.t === "number" && name === "backspace") {
      numBuf = numBuf.slice(0, -1); st.restoreN = Number(numBuf) || 0;
    }
    else if (name === "space") { row.t === "action" ? onAction(row.key) : activate(row); }
    else if (name === "return") {
      if (row.t === "action") onAction(row.key);
      else if (row.t === "radio" || row.t === "check" || row.t === "checklevel") activate(row);
    } else return;
    render();
  });
}
main();
