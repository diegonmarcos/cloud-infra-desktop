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
const LAUNCH = process.env.CAS_LAUNCH || "claude";

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

  console.log(`${C.b}${C.cy}  claude-superset-api · helper${C.r}`);
  console.log(`  ${C.dim}WG-only · token compression via Headroom${C.r}`);

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
  console.log("");
  console.log(`  ${C.b}[l]${C.r} launch ${LAUNCH} via superset    ${C.b}[d]${C.r} open dashboard`);
  console.log(`  ${C.b}[s]${C.r} refresh stats                ${C.b}[h]${C.r} health re-check`);
  console.log(`  ${C.b}[q]${C.r} quit\n`);
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
    if (k === "q" || (key?.ctrl && key?.name === "c")) { rl.close(); process.exit(0); }
    if (k === "h" || k === "s") return header();
    if (k === "d") { open(EP.dashboard); return header(); }
    if (k === "l") {
      if (process.stdin.isTTY) process.stdin.setRawMode(false);
      rl.close(); console.clear();
      const child = spawn("claude-superset", [], { stdio: "inherit" });
      child.on("exit", (c) => process.exit(c ?? 0));
      child.on("error", () => { console.log("claude-superset not found"); process.exit(1); });
    }
  });
}
main();
