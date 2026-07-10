#!/usr/bin/env node
// claude-superset-tui — terminal helper/dashboard for claude-superset-api.
// No npm deps (node:readline + global fetch). Endpoints come from the env
// (CAS_PROXY / CAS_API / CAS_OLLAMA / CAS_COMPRESS / CAS_DASHBOARD /
//  CAS_MCP_* / CAS_ANTHROPIC), injected by the Nix wrapper from the
// data-driven claude-superset.json — nothing hardcoded.
//
// Universal: identical on desktop and termux. Shows live Headroom savings,
// health-checks every face (superset + MCPs + direct fallback), opens the
// dashboard, and launches `claude` routed through the proxy (graceful fallback).
// CAS_PLUGINS_SCRIPT — path to claude-plugins-status.sh (injected by Nix wrapper).
import readline from "node:readline";
import { spawn, spawnSync } from "node:child_process";

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
const LAUNCH = process.env.CAS_LAUNCH || "claude";
const PLUGINS_SCRIPT = process.env.CAS_PLUGINS_SCRIPT || `${process.env.HOME}/.claude/claude-plugins-status.sh`;

// Launch-options picker: cycle each field with a key, then [l] launches
// `claude-superset` with the matching flags. Data-driven cycles — add a value
// to a list and it just works.
const CYCLES = {
  face:     ["remote", "local", "claude"],
  headroom: ["on", "off"],
  ponytail: ["default", "off", "lite", "full", "ultra"],
  restore:  ["off", "count", "hours"],
};
// Preset ladders for [+]/[-] — count = sessions, hours = lookback window.
const RESTORE_PRESETS = { count: [1, 3, 5, 10, 20, 50], hours: [1, 4, 8, 24, 72, 168] };
const sel = { face: "remote", headroom: "on", ponytail: "default", restore: "off", restoreN: 5 };
const cycle = (k) => {
  const c = CYCLES[k]; sel[k] = c[(c.indexOf(sel[k]) + 1) % c.length];
  if (k === "restore" && sel.restore !== "off") sel.restoreN = RESTORE_PRESETS[sel.restore][0];
};
const bumpRestoreN = (dir) => {
  if (sel.restore === "off") return;
  const p = RESTORE_PRESETS[sel.restore];
  const i = Math.max(0, p.indexOf(sel.restoreN));
  sel.restoreN = p[Math.min(p.length - 1, Math.max(0, i + dir))];
};
// Build the argv for `claude-superset` from the current selection.
function selArgs() {
  if (sel.face === "claude") return ["claude"];       // plain — flags N/A
  const a = [sel.face];
  if (sel.headroom === "off") a.push("headroom", "off");
  if (sel.ponytail !== "default") a.push("ponytail", sel.ponytail);
  if (sel.restore === "count") a.push("restore", String(sel.restoreN));
  if (sel.restore === "hours") a.push("restore-hours", String(sel.restoreN));
  return a;
}

function pluginStatus() {
  try {
    const r = spawnSync("bash", [PLUGINS_SCRIPT, "--format", "plain"],
      { encoding: "utf8", timeout: 1000 });
    return r.status === 0 ? (r.stdout || "").trim() : "";
  } catch { return ""; }
}

const C = { r: "\x1b[0m", b: "\x1b[1m", dim: "\x1b[2m", g: "\x1b[32m", y: "\x1b[33m", red: "\x1b[31m", cy: "\x1b[36m" };
const ok = (b) => (b ? `${C.g}● up${C.r}` : `${C.red}○ down${C.r}`);
const fmt = (n) => Number(n || 0).toLocaleString();

// probe: r.ok=true only for 2xx; anyStatus=true for any HTTP response (reachability check)
async function probe(url, path = "/readyz", anyStatus = false) {
  try {
    const c = new AbortController();
    const t = setTimeout(() => c.abort(), 2500);
    const r = await fetch(`${url.replace(/\/$/, "")}${path}`, { signal: c.signal }).finally(() => clearTimeout(t));
    return anyStatus ? true : r.ok;
  } catch { return false; }
}

async function stats() {
  try {
    const r = await fetch(`${EP.compress.replace(/\/$/, "")}/stats`, { signal: AbortSignal.timeout(2500) });
    if (!r.ok) return null;
    return await r.json();
  } catch { return null; }
}

async function header() {
  console.clear();
  // all probes fire in parallel — 2.5 s timeout each
  const [p, a, o, c, ci, csvc, mmcp, ml, gw, gpers, direct] = await Promise.all([
    probe(EP.proxy),
    probe(EP.api,             "/health"),
    probe(EP.ollama,          "/api/version"),
    probe(EP.compress),
    probe(EP.mcps.c3_infra,   "/health"),
    probe(EP.mcps.c3_svc,     "/health"),
    probe(EP.mcps.mattermost, "/health"),
    probe(EP.mcps.mail,       "/health"),
    probe(EP.mcps.gws,        "/health"),
    probe(EP.mcps.gp,         "/health"),
    probe(EP.anthropic,       "/v1/models", true),  // any HTTP = reachable
  ]);
  const s = await stats();

  const row = (label, url, up, note) =>
    console.log(`  ${label.padEnd(11)}${url.padEnd(27)} ${ok(up)}   ${C.dim}(${note})${C.r}`);
  const sep = (title) =>
    console.log(`\n  ${C.dim}── ${title} ${"─".repeat(Math.max(0, 46 - title.length))}${C.r}`);

  const plugins = pluginStatus();

  console.log(`${C.b}${C.cy}  claude-superset-api · helper${C.r}`);
  console.log(`  ${C.dim}WG-only · token compression via Headroom${C.r}`);

  if (plugins) {
    sep("plugins");
    plugins.split(/\s+/).filter(Boolean).forEach(p => {
      const [label, val] = p.split(":");
      const on = val !== "off";
      const badge = on ? `${C.g}● ${val || "on"}${C.r}` : `${C.dim}○ off${C.r}`;
      console.log(`  ${(label || "").padEnd(11)}${" ".repeat(27)} ${badge}`);
    });
  }

  sep("superset");
  row("proxy",    EP.proxy,    p, "ANTHROPIC_BASE_URL · Headroom");
  row("api",      EP.api,      a, "OpenAI /v1");
  row("ollama",   EP.ollama,   o, "/api");
  row("compress", EP.compress, c, "compress/stats");

  sep("MCPs (WG-direct)");
  row("c3-infra",   EP.mcps.c3_infra,   ci,    "infra tools");
  row("c3-svc",     EP.mcps.c3_svc,     csvc,  "services tools");
  row("mattermost", EP.mcps.mattermost, mmcp,  "chat MCP");
  row("mail",       EP.mcps.mail,       ml,    "email MCP");
  row("gws",        EP.mcps.gws,        gw,    "Google Workspace");
  row("gp",         EP.mcps.gp,         gpers, "Google Personal");

  sep("fallback");
  row("direct", EP.anthropic, direct, "Anthropic API (no proxy)");

  if (s) {
    const ratio = s.lifetime_ratio != null ? (s.lifetime_ratio * 100).toFixed(1) : "0.0";
    console.log(`\n  ${C.y}savings${C.r}  ${C.b}${fmt(s.tokens_saved)}${C.r} tokens removed  ` +
                `(${C.g}${ratio}%${C.r} of ${fmt(s.tokens_before)} over ${fmt(s.compressions)} compressions)`);
  } else {
    console.log(`\n  ${C.dim}savings  (compress face unreachable)${C.r}`);
  }
  // Launch-options picker — tick the values, then [l] launches with them.
  sep("launch options");
  const pick = (k, v) => `${k} ${C.g}${C.b}[${v}]${C.r}`;
  const faceName = { remote: "remote (R)", local: "local (L)", claude: "claude/plain (C)" }[sel.face];
  console.log(`  ${pick("face", faceName)}`);
  if (sel.face === "claude") {
    console.log(`  ${C.dim}headroom/ponytail/restore N/A for plain claude${C.r}`);
  } else {
    console.log(`  ${pick("headroom", sel.headroom)}   ${pick("ponytail", sel.ponytail)}`);
    const restoreLabel = sel.restore === "off" ? "off (fresh session)"
      : `${sel.restore === "count" ? "last N sessions" : "sessions in last N hours"} · N=${sel.restoreN}`;
    console.log(`  ${pick("restore", restoreLabel)}`);
  }

  console.log("");
  console.log(`  ${C.b}[f]${C.r} face   ${C.b}[c]${C.r} headroom   ${C.b}[p]${C.r} ponytail   ${C.b}[r]${C.r} restore mode`);
  if (sel.face !== "claude" && sel.restore !== "off")
    console.log(`  ${C.b}[+/-]${C.r} adjust N (${RESTORE_PRESETS[sel.restore].join(", ")})`);
  console.log(`  ${C.b}[l]${C.r} launch: ${C.cy}claude-superset ${selArgs().join(" ")}${C.r}`);
  console.log(`  ${C.b}[d]${C.r} dashboard   ${C.b}[s]${C.r} stats   ${C.b}[h]${C.r} re-check   ${C.b}[q]${C.r} quit\n`);
}

function open(url) {
  const opener = process.platform === "darwin" ? "open" : "xdg-open";
  spawn(opener, [url], { stdio: "ignore", detached: true }).on("error", () => {
    console.log(`  ${C.y}open manually:${C.r} ${url}`);
  }).unref();
}

async function main() {
  await header();
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  readline.emitKeypressEvents(process.stdin, rl);
  if (process.stdin.isTTY) process.stdin.setRawMode(true);
  process.stdin.on("keypress", async (_str, key) => {
    const k = key?.name;
    if (k === "q" || (key?.ctrl && key?.name === "c")) { if (process.stdin.isTTY) process.stdin.setRawMode(false); rl.close(); process.exit(0); }
    if (k === "h" || k === "s") return header();
    if (k === "d") { open(EP.dashboard); return header(); }
    if (k === "f") { cycle("face"); return header(); }
    if (k === "c") { cycle("headroom"); return header(); }
    if (k === "p") { cycle("ponytail"); return header(); }
    if (k === "r") { cycle("restore"); return header(); }
    if (k === "+" || k === "=" || k === "kpplus") { bumpRestoreN(1); return header(); }
    if (k === "-" || k === "kpminus") { bumpRestoreN(-1); return header(); }
    if (k === "l") {
      if (process.stdin.isTTY) process.stdin.setRawMode(false);
      rl.close(); console.clear();
      const child = spawn("claude-superset", selArgs(), { stdio: "inherit" });
      child.on("exit", (c) => process.exit(c ?? 0));
      child.on("error", () => { console.log("claude-superset not found"); process.exit(1); });
    }
  });
}
main();
