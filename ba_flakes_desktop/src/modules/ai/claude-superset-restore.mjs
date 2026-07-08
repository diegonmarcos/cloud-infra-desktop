#!/usr/bin/env node
// claude-superset-restore.mjs — scan Claude Code sessions under
// ~/.claude/projects/*/*.jsonl, select the most recent ones (by count or by
// age in hours), and emit a konsole `--tabs-from-file` layout: one tab per
// session, titled with the session's summary/first-prompt, running
// `claude-superset <mode> --resume <id>` in the session's own cwd.
//
// Usage:  node claude-superset-restore.mjs <mode> <count|hours> <value>
//   mode   remote | local  (forwarded to claude-superset in each tab)
//   count  <value> = how many most-recent sessions to restore
//   hours  <value> = restore sessions touched within the last <value> hours
//
// Prints the tabs file to stdout (empty output => no sessions matched).
import fs from "node:fs";
import path from "node:path";

const [, , mode = "remote", selector = "count", rawValue = "0"] = process.argv;
const value = Number(rawValue);
if (!Number.isFinite(value) || value <= 0) {
  process.stderr.write(`invalid value: ${rawValue}\n`);
  process.exit(2);
}

const base = path.join(process.env.HOME, ".claude", "projects");
let projectDirs = [];
try {
  projectDirs = fs
    .readdirSync(base)
    .map((p) => path.join(base, p))
    .filter((p) => fs.statSync(p).isDirectory());
} catch {
  process.exit(0); // no projects dir => nothing to restore
}

// One friendly title per session: prefer a `summary` line, else the first user
// prompt text, else the short id. cwd comes from the first event carrying one.
function inspect(file) {
  let cwd = null;
  let summary = null;
  let firstPrompt = null;
  const lines = fs.readFileSync(file, "utf8").split("\n");
  for (const line of lines) {
    if (!line) continue;
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }
    if (!cwd && typeof o.cwd === "string") cwd = o.cwd;
    if (!summary && o.type === "summary" && o.summary) summary = String(o.summary);
    if (!firstPrompt && o.type === "user") {
      const c = o.message?.content;
      const txt =
        typeof c === "string"
          ? c
          : Array.isArray(c)
            ? c.find((b) => b?.type === "text")?.text
            : null;
      if (txt && !txt.startsWith("<")) firstPrompt = txt;
    }
  }
  return { cwd, summary, firstPrompt };
}

function clean(s, id) {
  const t = (s || id.slice(0, 8))
    .replace(/[\r\n;]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 40);
  return t || id.slice(0, 8);
}

const sessions = [];
for (const dir of projectDirs) {
  for (const name of fs.readdirSync(dir)) {
    if (!name.endsWith(".jsonl")) continue;
    const file = path.join(dir, name);
    let mtime;
    try {
      mtime = fs.statSync(file).mtimeMs;
    } catch {
      continue;
    }
    sessions.push({ id: name.slice(0, -6), file, mtime });
  }
}
sessions.sort((a, b) => b.mtime - a.mtime);

let picked;
if (selector === "hours") {
  const cutoff = Date.now() - value * 3600_000;
  picked = sessions.filter((s) => s.mtime >= cutoff);
} else {
  picked = sessions.slice(0, value);
}

const out = [];
for (const s of picked) {
  const { cwd, summary, firstPrompt } = inspect(s.file);
  const title = clean(summary || firstPrompt, s.id);
  const workdir = cwd || process.env.HOME;
  out.push(
    `title: ${title} ;; workdir: ${workdir} ;; command: claude-superset ${mode} --resume ${s.id}`,
  );
}
if (out.length) process.stdout.write(out.join("\n") + "\n");
