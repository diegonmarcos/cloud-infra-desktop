#!/usr/bin/env node
// nix-switch-progress.mjs — parse nix's `--log-format internal-json` activity
// stream (on stdin) into a real percentage and drive a kdialog ProgressDialog
// over D-Bus. Invoked by programs/nix-switch-progress.nix; never run directly.
//
// nix emits, on stderr, lines containing `@nix {…json…}`. Relevant events:
//   action:"start"  type:105 (actBuild)      text:"building '/nix/store/…drv'"
//   action:"start"  type:100 (actCopyPath)   text:"copying path '…'"
//   action:"result" type:105 (resProgress)   fields:[done, expected, running, failed]
// resProgress is emitted on the aggregate build/copy/substitute activities, so
// summing done/expected across activities that declare an expected>0 yields a
// faithful overall %. The current build's drv name becomes the label.
//
// kdialog ProgressDialog is driven with the canonical qdbus idiom:
//   qdbus <svc> <obj> Set "" value <n>      (set bar position)
//   qdbus <svc> <obj> setLabelText <text>
//   qdbus <svc> <obj> wasCancelled          (poll Cancel button)
// Env: NSP_SVC, NSP_PATH (the "service /object" pair), NSP_QDBUS (qdbus binary),
//      NSP_CAP (cap % until the command exits, default 99).
import { spawnSync } from "node:child_process";
import { createInterface } from "node:readline";

const SVC = process.env.NSP_SVC || "";
const OBJ = process.env.NSP_PATH || "";
const QDBUS = process.env.NSP_QDBUS || "qdbus";
const CAP = Number(process.env.NSP_CAP || "99");

const acts = new Map(); // activityId -> [done, expected]
let lastPct = -1;
let lastLabel = "";

const qd = (...args) =>
  SVC ? spawnSync(QDBUS, [SVC, OBJ, ...args], { encoding: "utf8" }) : { stdout: "" };
const setValue = (n) => qd("Set", "", "value", String(n));
const setLabel = (t) => qd("setLabelText", t);
const wasCancelled = () => /true/.test((qd("wasCancelled").stdout || "").trim());

const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  const i = line.indexOf("@nix ");
  if (i < 0) return;
  let j;
  try { j = JSON.parse(line.slice(i + 5)); } catch { return; }

  if (j.action === "start" && typeof j.text === "string") {
    if (j.type === 105) {
      const m = j.text.match(/([^/]+)\.drv/);
      lastLabel = m ? "building " + m[1] : j.text;
    } else if (j.type === 100 || j.type === 108) {
      lastLabel = j.text;
    }
  } else if (j.action === "result" && j.type === 105 && Array.isArray(j.fields)) {
    acts.set(j.id, [Number(j.fields[0]) || 0, Number(j.fields[1]) || 0]);
  } else {
    return;
  }

  let done = 0, exp = 0;
  for (const [d, e] of acts.values()) { if (e > 0) { done += d; exp += e; } }
  const pct = exp > 0 ? Math.min(CAP, Math.round((done / exp) * 100)) : 0;
  if (pct !== lastPct) { setValue(pct); lastPct = pct; }
  if (lastLabel) setLabel(`${lastLabel}   ${done}/${exp || "?"}`);
  if (wasCancelled()) process.exit(130);
});
rl.on("close", () => process.exit(0));
