#!/usr/bin/env node
// claude-superset-tui — terminal helper/dashboard for the claude-api-superset.
// No npm deps (node:readline + global fetch). Endpoints come from the env
// (CAS_PROXY / CAS_API / CAS_OLLAMA / CAS_COMPRESS / CAS_DASHBOARD), injected by
// the Nix wrapper from the data-driven claude-superset.json — nothing hardcoded.
//
// Universal: identical on desktop and termux. Lets you see live Headroom savings,
// health-check every face, open the dashboard, and launch `claude` routed through
// the superset proxy (with graceful fallback to direct Anthropic).
import readline from "node:readline";
import { spawn } from "node:child_process";

const EP = {
  proxy:     process.env.CAS_PROXY     || "http://10.0.0.6:8789",
  api:       process.env.CAS_API       || "http://10.0.0.6:3117",
  ollama:    process.env.CAS_OLLAMA    || "http://10.0.0.6:11436",
  compress:  process.env.CAS_COMPRESS  || "http://10.0.0.6:8788",
  dashboard: process.env.CAS_DASHBOARD || "http://10.0.0.6:8788/dashboard",
};
const LAUNCH = process.env.CAS_LAUNCH || "claude"; // claude-malloc on termux

const C = { r: "\x1b[0m", b: "\x1b[1m", dim: "\x1b[2m", g: "\x1b[32m", y: "\x1b[33m", red: "\x1b[31m", cy: "\x1b[36m" };
const ok = (b) => (b ? `${C.g}● up${C.r}` : `${C.red}○ down${C.r}`);
const fmt = (n) => Number(n || 0).toLocaleString();

async function probe(url, path = "/readyz") {
  try {
    const c = new AbortController();
    const t = setTimeout(() => c.abort(), 2500);
    const r = await fetch(`${url.replace(/\/$/, "")}${path}`, { signal: c.signal }).finally(() => clearTimeout(t));
    return r.ok;
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
  const [p, a, o, c] = await Promise.all([
    probe(EP.proxy), probe(EP.api, "/health"), probe(EP.ollama, "/api/version"), probe(EP.compress),
  ]);
  const s = await stats();
  console.log(`${C.b}${C.cy}  claude-api-superset · helper${C.r}`);
  console.log(`  ${C.dim}WG-only · token compression via Headroom${C.r}\n`);
  console.log(`  proxy   ${EP.proxy.padEnd(24)} ${ok(p)}   ${C.dim}(ANTHROPIC_BASE_URL target)${C.r}`);
  console.log(`  api     ${EP.api.padEnd(24)} ${ok(a)}   ${C.dim}(OpenAI /v1)${C.r}`);
  console.log(`  ollama  ${EP.ollama.padEnd(24)} ${ok(o)}   ${C.dim}(/api)${C.r}`);
  console.log(`  compress${EP.compress.padEnd(24)} ${ok(c)}   ${C.dim}(dashboard/stats)${C.r}`);
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
      // Hand off to the routing wrapper, which sets ANTHROPIC_BASE_URL + falls back.
      const child = spawn("claude-superset", [], { stdio: "inherit" });
      child.on("exit", (c) => process.exit(c ?? 0));
      child.on("error", () => { console.log("claude-superset not found"); process.exit(1); });
    }
  });
}
main();
