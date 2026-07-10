#!/usr/bin/env node
// claude-superset-tui — full-screen launch composer + infra dashboard.
// No npm deps (node:readline raw-mode + ANSI). TTY-SAFE: only ASCII glyphs +
// ANSI colors, so it renders identically on a bare Linux console, xterm and
// konsole. Data is OFFLINE (read instantly at startup: MCP registry, plugins,
// hooks, local sessions) or NETWORK (probed ONLY on Refresh — nothing hits the
// wire on open, so it never blocks/freezes). Each probe is independent + hard
// timeout'd and patches only its own field, re-rendering as answers arrive.
//
//   Up/Down move   Space toggle/select   Left/Right change   0-9 type N
//   r / Refresh probe network   Enter activate   q quit
//
//   (*)/( ) selection (pick one)    [x]/[ ] checkbox (toggle)
import readline from "node:readline";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// ── endpoints (from the Nix wrapper env; sane fallbacks) ────────────────────
const EP = {
  proxy:     process.env.CAS_PROXY     || "http://10.0.0.6:8789",
  api:       process.env.CAS_API       || "http://10.0.0.6:3117",
  ollama:    process.env.CAS_OLLAMA    || "http://10.0.0.6:11436",
  compress:  process.env.CAS_COMPRESS  || "http://10.0.0.6:8788",
  anthropic: process.env.CAS_ANTHROPIC || "https://api.anthropic.com",
};
const MESH = (() => { try { return JSON.parse(process.env.CAS_MESH || "{}"); } catch { return {}; } })();
const SELF = "claude-superset";
const HOME = os.homedir();
const CFG = process.env.CLAUDE_CONFIG_DIR || path.join(HOME, ".claude");
const RESTORE_PRESETS = { count: [1, 3, 5, 10, 20, 50], hours: [1, 4, 8, 24, 72, 168] };
const PONY_LEVELS = ["lite", "full", "ultra"];

const C = {
  r: "\x1b[0m", b: "\x1b[1m", dim: "\x1b[2m", inv: "\x1b[7m",
  g: "\x1b[32m", y: "\x1b[33m", red: "\x1b[31m", cy: "\x1b[36m", mag: "\x1b[35m", blu: "\x1b[34m",
};
const strip = (s) => s.replace(/\x1b\[[0-9;]*m/g, "");
const padE = (s, n) => { const w = strip(s).length; return w >= n ? s : s + " ".repeat(n - w); };
const padS = (s, n) => { const w = strip(s).length; return w >= n ? s : " ".repeat(n - w) + s; };
const W = 70;
const RULE = "-".repeat(W);
const SPIN = ["|", "/", "-", "\\"];
let spin = 0, spinTimer = null;
// beautiful, TTY-safe section header:  --[ TITLE ]----------------[ right ]--
function secHead(title, right = "") {
  const left = `--[ ${title} ]`;
  const rt = right ? `[ ${right} ]--` : "--";
  const mid = "-".repeat(Math.max(2, W - strip(left).length - strip(rt).length));
  return `  ${C.dim}--${C.r}${C.b}${C.blu}[ ${title} ]${C.r}${C.dim}${mid}${right ? C.r + C.y + `[ ${right} ]` + C.dim : ""}--${C.r}`;
}

// ── offline data (read instantly at startup — no network) ───────────────────
function readJSON(p) { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } }
function loadMcps() {
  const j = readJSON(path.join(HOME, ".mcp.json")) || readJSON(path.join(HOME, ".claude.json")) || {};
  return Object.entries(j.mcpServers || {}).map(([name, v]) => {
    const type = v.type || (v.url ? "http" : "stdio");
    let host = null; try { if (v.url) host = new URL(v.url).host; } catch {}
    return { name, type, url: v.url || null, host, st: undefined };
  });
}
function loadPlugins() {
  const j = readJSON(path.join(CFG, "claude-plugins.json")) || readJSON(path.join(HOME, ".claude", "claude-plugins.json")) || { plugins: [] };
  return (j.plugins || []).map((p) => ({ id: p.id, label: p.label || p.id, icon: p.icon || "*" }));
}
function loadHooks() {
  try {
    return fs.readdirSync(path.join(CFG, "hooks")).filter((f) => !f.startsWith(".")).map((f) => f.replace(/\.(sh|json|md)$/, ""));
  } catch { return []; }
}
function inspectTitle(text, id) {
  let ct = null, slug = null, ai = null, fp = null;
  for (const line of text.split("\n")) {
    if (!line) continue;
    let o; try { o = JSON.parse(line); } catch { continue; }
    if (o.customTitle) ct = String(o.customTitle);
    if (o.aiTitle) ai = String(o.aiTitle);
    if (!slug && o.slug) slug = String(o.slug);
    if (!fp && o.type === "user") {
      const c = o.message?.content;
      const t = typeof c === "string" ? c : Array.isArray(c) ? c.find((b) => b?.type === "text")?.text : null;
      if (t && !t.startsWith("<")) fp = t;
    }
  }
  return (ct || slug || ai || fp || id.slice(0, 8)).replace(/[\r\n]+/g, " ").trim().slice(0, 34);
}
const ago = (ms) => {
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 90) return `${Math.round(s)}s`;
  if (s < 5400) return `${Math.round(s / 60)}m`;
  if (s < 172800) return `${Math.round(s / 3600)}h`;
  return `${Math.round(s / 86400)}d`;
};
function loadLocalSessions() {
  const base = path.join(HOME, ".claude", "projects");
  const out = [];
  let dirs = []; try { dirs = fs.readdirSync(base).map((d) => path.join(base, d)); } catch { return []; }
  for (const dir of dirs) {
    let names = []; try { if (!fs.statSync(dir).isDirectory()) continue; names = fs.readdirSync(dir); } catch { continue; }
    for (const n of names) {
      if (!n.endsWith(".jsonl")) continue;
      const f = path.join(dir, n);
      try { out.push({ id: n.slice(0, -6), f, mtime: fs.statSync(f).mtimeMs }); } catch {}
    }
  }
  out.sort((a, b) => b.mtime - a.mtime);
  return out.slice(0, 10).map((s) => {
    let title = s.id.slice(0, 8);
    try { title = inspectTitle(fs.readFileSync(s.f, "utf8"), s.id); } catch {}
    return { id: s.id, title, age: ago(s.mtime) };
  });
}

// ── network probes (fired ONLY on Refresh) ──────────────────────────────────
async function timed(url, sub, anyStatus = false) {
  const t0 = Date.now();
  try {
    const c = new AbortController(); const t = setTimeout(() => c.abort(), 1800);
    const r = await fetch(`${url.replace(/\/$/, "")}${sub}`, { signal: c.signal, redirect: "manual" }).finally(() => clearTimeout(t));
    return { up: anyStatus ? true : r.ok, ms: Date.now() - t0 };
  } catch { return "t/o"; }
}
function pingHost(ip) {
  return new Promise((resolve) => {
    let done = false; const fin = (v) => { if (!done) { done = true; resolve(v); } };
    let child; try { child = spawn("ping", ["-c", "1", "-W", "1", ip]); } catch { return fin("t/o"); }
    const kill = setTimeout(() => { try { child.kill("SIGKILL"); } catch {} fin("t/o"); }, 2000);
    let out = ""; child.stdout.on("data", (d) => (out += d));
    child.on("error", () => { clearTimeout(kill); fin("t/o"); });
    child.on("close", () => { clearTimeout(kill); const m = out.match(/time[=<]([\d.]+)\s*ms/); fin(m ? { up: true, ms: Math.round(Number(m[1])) } : "t/o"); });
  });
}

// ── state — ALL plugins ON by default ───────────────────────────────────────
const st = { face: "remote", headroom: true, ponytail: true, ponyLevel: "full", restore: "off", restoreN: 5 };
let numBuf = "";
const OFF = { mcps: loadMcps(), plugins: loadPlugins(), hooks: loadHooks(), sessions: loadLocalSessions() };
const NET = { proxy: undefined, api: undefined, ollama: undefined, compress: undefined, direct: undefined, mesh: {}, tokens: undefined, server: undefined };
Object.keys(MESH).forEach((k) => (NET.mesh[k] = undefined));
let refreshing = false, tearing = false;

function selArgs() {
  const n = String(Math.max(1, st.restoreN || 1));
  const a = [st.face];
  if (st.face !== "claude") { if (!st.headroom) a.push("headroom", "off"); a.push("ponytail", st.ponytail ? st.ponyLevel : "off"); }
  if (st.restore === "count") a.push("restore", n);
  if (st.restore === "hours") a.push("restore-hours", n);
  return a;
}

// probe progress: pending / total (for the animated STATUS header)
function progress() {
  const slots = [NET.proxy, NET.api, NET.ollama, NET.compress, NET.direct, NET.tokens, NET.server,
    ...Object.values(NET.mesh), ...OFF.mcps.filter((m) => m.type === "http").map((m) => m.st)];
  const total = slots.length;
  const pending = slots.filter((s) => s === null).length;
  return { total, done: total - pending };
}

// ── refresh: fire every probe independently ─────────────────────────────────
function refresh() {
  if (refreshing) return;
  refreshing = true;
  const patch = (fn) => { fn(); if (!tearing) render(); };
  NET.proxy = NET.api = NET.ollama = NET.compress = NET.direct = null;
  NET.tokens = null; NET.server = null;
  Object.keys(NET.mesh).forEach((k) => (NET.mesh[k] = null));
  OFF.mcps.forEach((m) => (m.st = m.type === "http" ? null : "stdio"));
  // spinner animation — bounded, self-stops when all resolve or after 2.6s
  if (spinTimer) clearInterval(spinTimer);
  spinTimer = setInterval(() => {
    spin = (spin + 1) % SPIN.length;
    if (!tearing) render();
    if (progress().done >= progress().total) { clearInterval(spinTimer); spinTimer = null; }
  }, 110);
  render();
  timed(EP.proxy, "/readyz").then((v) => patch(() => (NET.proxy = v)));
  timed(EP.api, "/health").then((v) => patch(() => (NET.api = v)));
  timed(EP.ollama, "/api/version").then((v) => patch(() => (NET.ollama = v)));
  timed(EP.compress, "/readyz").then((v) => patch(() => (NET.compress = v)));
  timed(EP.anthropic, "/v1/models", true).then((v) => patch(() => (NET.direct = v)));
  for (const [name, ip] of Object.entries(MESH)) pingHost(ip).then((v) => patch(() => (NET.mesh[name] = v)));
  for (const m of OFF.mcps) if (m.type === "http" && m.url) timed(m.url, "", true).then((v) => patch(() => (m.st = v)));
  fetch(`${EP.compress.replace(/\/$/, "")}/stats`, { signal: AbortSignal.timeout(1800) })
    .then((r) => r.json()).then((j) => patch(() => (NET.tokens = j))).catch(() => patch(() => (NET.tokens = "t/o")));
  fetch(`${EP.api.replace(/\/$/, "")}/sessions`, { signal: AbortSignal.timeout(1800) })
    .then((r) => r.json()).then((j) => patch(() => (NET.server = Array.isArray(j) ? j.sort((a, b) => (b.mtime || 0) - (a.mtime || 0)).slice(0, 10) : []))).catch(() => patch(() => (NET.server = "t/o")));
  setTimeout(() => { refreshing = false; if (spinTimer) { clearInterval(spinTimer); spinTimer = null; } if (!tearing) render(); }, 2600);
}

// ── focusable form rows ─────────────────────────────────────────────────────
function buildRows() {
  const rows = [];
  rows.push({ t: "sec", text: "FACE" });
  rows.push({ t: "radio", grp: "face", val: "remote", label: "remote", note: "WG compression proxy" });
  rows.push({ t: "radio", grp: "face", val: "local",  label: "local",  note: "container on THIS host" });
  rows.push({ t: "radio", grp: "face", val: "claude", label: "claude", note: "plain claude (restore still works)" });
  if (st.face !== "claude") {
    rows.push({ t: "sec", text: "PLUGINS" });
    rows.push({ t: "check", key: "headroom", label: "Headroom", note: "compression proxy" });
    rows.push({ t: "checklevel", key: "ponytail", label: "Ponytail", note: "Left/Right level" });
  }
  rows.push({ t: "sec", text: "RESTORE" });
  rows.push({ t: "radio", grp: "restore", val: "off",   label: "off",   note: "fresh session" });
  rows.push({ t: "radio", grp: "restore", val: "count", label: "count", note: "last N sessions" });
  rows.push({ t: "radio", grp: "restore", val: "hours", label: "hours", note: "sessions from last N hours" });
  if (st.restore !== "off") rows.push({ t: "number", key: "restoreN", label: "N", note: "type digits or Left/Right" });
  rows.push({ t: "sec", text: "ACTION" });
  rows.push({ t: "action", key: "refresh" });
  rows.push({ t: "action", key: "launch" });
  rows.push({ t: "action", key: "quit" });
  return rows;
}
const focusableT = ["radio", "check", "checklevel", "number", "action"];
let rows = buildRows();
let focus = 0;
const focusables = () => rows.map((r, i) => (focusableT.includes(r.t) ? i : -1)).filter((i) => i >= 0);

// ── status: ASCII-safe colored tokens ───────────────────────────────────────
function dm(v) {
  if (v === undefined) return `${C.dim}--${C.r}     `;
  if (v === null) return `${C.dim}..${C.r}     `;
  if (v === "t/o") return `${C.y}t/o${C.r}    `;
  if (v === "stdio") return `${C.blu}stdio${C.r}  `;
  return `${v.up ? C.g + "up" : C.red + "dn"}${C.r} ${padS(`${v.ms}ms`, 5)}`;
}
function statusLines() {
  const L = [];
  const kv = (k, s) => `    ${C.dim}${padE(k, 13)}${C.r}${s}`;
  const pr = progress();
  const right = refreshing ? `${SPIN[spin]} probing ${pr.done}/${pr.total}` : (pr.done ? "ready" : "idle");
  L.push(secHead("STATUS", right));
  L.push(kv("services", ["proxy", "api", "ollama", "compress", "direct"].map((k, i) =>
    `${C.dim}${["proxy", "api", "ollama", "compr", "direct"][i]}${C.r} ${dm(NET[k])}`).join(" ")));
  const mesh = Object.entries(MESH).map(([n]) => `${C.dim}${n}${C.r} ${dm(NET.mesh[n])}`);
  if (mesh.length) L.push(kv("mesh", mesh.join(" ")));
  L.push(kv(`mcp (${OFF.mcps.length})`, ""));
  for (let i = 0; i < OFF.mcps.length; i += 3)
    L.push("      " + OFF.mcps.slice(i, i + 3).map((m) => padE(`${C.mag}${padE(m.name, 20)}${C.r} ${dm(m.st)}`, 36)).join(""));
  let tok;
  if (NET.tokens === undefined) tok = `${C.dim}--${C.r}`;
  else if (NET.tokens === null) tok = `${C.dim}..${C.r}`;
  else if (NET.tokens === "t/o") tok = `${C.y}t/o${C.r}`;
  else {
    const j = NET.tokens, num = (x) => Number(x || 0).toLocaleString();
    tok = `${C.y}${num(j.tokens_saved)}${C.r} saved ${C.dim}(${((j.lifetime_ratio || 0) * 100).toFixed(0)}%)${C.r}  ` +
      `${C.dim}before${C.r} ${num(j.tokens_before)}  ${C.dim}after${C.r} ${num(j.tokens_after)}  ${C.dim}compress${C.r} ${num(j.compressions)}  ${C.dim}calls${C.r} ${num(j.calls)}`;
  }
  L.push(kv("tokens", tok));
  L.push(kv(`hooks (${OFF.hooks.length})`, OFF.hooks.map((h) => `${C.dim}${h}${C.r}`).join("  ") || `${C.dim}none${C.r}`));
  L.push(kv(`plugins (${OFF.plugins.length})`, OFF.plugins.map((p) => `${C.mag}${p.icon}${C.r} ${p.label}`).join("   ")));
  L.push(kv(`local (${OFF.sessions.length})`, ""));
  OFF.sessions.forEach((s) => L.push(`      ${C.dim}${padS(s.age, 4)}${C.r}  ${s.title}`));
  let sh;
  if (NET.server === undefined) sh = `${C.dim}-- Refresh to load${C.r}`;
  else if (NET.server === null) sh = `${C.dim}..${C.r}`;
  else if (NET.server === "t/o") sh = `${C.y}t/o (hub unreachable)${C.r}`;
  else sh = NET.server.length ? "" : `${C.dim}none${C.r}`;
  L.push(kv(`server (${Array.isArray(NET.server) ? NET.server.length : "-"})`, sh));
  if (Array.isArray(NET.server)) NET.server.forEach((s) =>
    L.push(`      ${C.dim}${padE(s.device || "?", 16)}${padS(s.mtime ? ago(s.mtime) : "", 5)}${C.r}  ${(s.id || "").slice(0, 8)}`));
  return L;
}

// ── render ──────────────────────────────────────────────────────────────────
function render() {
  if (tearing) return;
  rows = buildRows();
  const fl = focusables();
  if (focus >= fl.length) focus = fl.length - 1;
  if (focus < 0) focus = 0;
  const focIdx = fl[focus];
  const L = [];
  const bar = `+${"-".repeat(W)}+`;
  L.push(`  ${C.b}${C.cy}${bar}${C.r}`);
  L.push(`  ${C.b}${C.cy}|${C.r} ${C.b}${C.mag}C L A U D E - S U P E R S E T${C.r}${padE("", W - 30)}${C.b}${C.cy}|${C.r}`);
  L.push(`  ${C.b}${C.cy}|${C.r} ${C.dim}launch composer  &  live infra dashboard${padE("", W - 42)}${C.r}${C.b}${C.cy}|${C.r}`);
  L.push(`  ${C.b}${C.cy}${bar}${C.r}`);
  L.push(`   ${C.g}>${C.r} ${C.cy}${SELF} ${selArgs().join(" ")}${C.r}`);
  L.push("");
  L.push(secHead("COMPOSE", `${st.face}`));
  rows.forEach((row, i) => {
    const foc = i === focIdx;
    const cur = foc ? `${C.cy}${C.b}>${C.r} ` : "  ";
    const hl = (s) => (foc ? `${C.inv}${s}${C.r}` : s);
    if (row.t === "sec") return L.push(`   ${C.dim}${row.text}${C.r}`);
    let body = "";
    if (row.t === "radio") body = `${st[row.grp] === row.val ? `${C.g}(*)${C.r}` : `${C.dim}( )${C.r}`} ${hl(padE(row.label, 8))} ${C.dim}${row.note}${C.r}`;
    else if (row.t === "check") body = `${st[row.key] ? `${C.g}[x]${C.r}` : `${C.dim}[ ]${C.r}`} ${hl(padE(row.label, 8))} ${C.dim}${row.note}${C.r}`;
    else if (row.t === "checklevel") { const lvl = st[row.key] ? `${C.mag}< ${st.ponyLevel} >${C.r}` : `${C.dim}(off)${C.r}`; body = `${st[row.key] ? `${C.g}[x]${C.r}` : `${C.dim}[ ]${C.r}`} ${hl(padE(row.label, 8))} ${lvl}  ${C.dim}${row.note}${C.r}`; }
    else if (row.t === "number") { const shown = foc && numBuf !== "" ? numBuf : String(st.restoreN); body = `    ${hl(row.label)} ${foc ? `${C.inv} ${shown}_ ${C.r}` : `${C.mag}< ${shown} >${C.r}`}  ${C.dim}${row.note}${C.r}`; }
    else if (row.t === "action") { const A = { refresh: [" Refresh ", C.blu], launch: [" LAUNCH ", C.g], quit: [" Quit ", C.dim] }[row.key]; body = foc ? `${C.inv}${A[1]}${A[0]}${C.r}` : `${A[1]}[${A[0].trim()}]${C.r}`; }
    L.push(`${cur}${body}`);
  });
  L.push("");
  statusLines().forEach((l) => L.push(l));
  L.push("");
  L.push(secHead("KEYS"));
  L.push(`   ${C.dim}Up/Down move  Space select  Left/Right change  0-9 type N  r Refresh  Enter go  q quit${C.r}`);
  // flicker-free: home cursor, clear each line to EOL, clear below — no full wipe.
  process.stdout.write("\x1b[H" + L.map((l) => l + "\x1b[K").join("\n") + "\x1b[0J");
}

// ── input ─────────────────────────────────────────────────────────────────
function activate(row) {
  if (row.t === "radio") st[row.grp] = row.val;
  else if (row.t === "check" || row.t === "checklevel") st[row.key] = !st[row.key];
}
function adjust(row, dir) {
  if (row.t === "checklevel" && st.ponytail) { const i = PONY_LEVELS.indexOf(st.ponyLevel); st.ponyLevel = PONY_LEVELS[(i + dir + PONY_LEVELS.length) % PONY_LEVELS.length]; }
  else if (row.t === "number") { numBuf = ""; const p = RESTORE_PRESETS[st.restore] || []; const i = Math.max(0, p.indexOf(st.restoreN)); st.restoreN = p[Math.min(p.length - 1, Math.max(0, i + dir))]; }
  else if (row.t === "radio") { const opts = rows.filter((r) => r.t === "radio" && r.grp === row.grp).map((r) => r.val); const i = opts.indexOf(st[row.grp]); st[row.grp] = opts[(i + dir + opts.length) % opts.length]; }
}
function teardown() { tearing = true; if (process.stdin.isTTY) process.stdin.setRawMode(false); process.stdout.write("\x1b[?25h"); }
function quit() { teardown(); process.exit(0); }
function launch() {
  teardown(); process.stdout.write("\x1b[2J\x1b[H");
  const ch = spawn(SELF, selArgs(), { stdio: "inherit" });
  ch.on("exit", (c) => process.exit(c ?? 0));
  ch.on("error", () => { console.log(`${SELF} not found on PATH`); process.exit(1); });
}
function main() {
  if (!process.stdin.isTTY) { console.log(`claude-superset TUI needs a terminal. Would launch: ${SELF} ${selArgs().join(" ")}`); process.exit(0); }
  process.stdout.write("\x1b[2J\x1b[H\x1b[?25l"); // one-time clear + hide cursor
  render();
  readline.emitKeypressEvents(process.stdin);
  process.stdin.setRawMode(true);
  process.stdin.on("keypress", (str, key) => {
    const fl = focusables();
    const row = rows[fl[focus]];
    const name = key?.name;
    const onAction = (k) => (k === "refresh" ? refresh() : k === "launch" ? launch() : quit());
    if (name === "q" || (key?.ctrl && name === "c")) return quit();
    if (name === "r") return refresh();
    if (name === "up" || name === "k") { numBuf = ""; focus = (focus - 1 + fl.length) % fl.length; }
    else if (name === "down" || name === "j" || name === "tab") { numBuf = ""; focus = (focus + 1) % fl.length; }
    else if (name === "left") adjust(row, -1);
    else if (name === "right") adjust(row, 1);
    else if (row?.t === "number" && str && /^[0-9]$/.test(str)) { numBuf = (numBuf + str).slice(0, 4).replace(/^0+/, "") || "0"; st.restoreN = Number(numBuf); }
    else if (row?.t === "number" && name === "backspace") { numBuf = numBuf.slice(0, -1); st.restoreN = Number(numBuf) || 0; }
    else if (name === "space" || name === "return") { row.t === "action" ? onAction(row.key) : activate(row); }
    else return;
    render();
  });
}
main();
