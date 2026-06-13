#!/usr/bin/env node
// Generate launcher `favorites` hotseat SQL from env-passed, already-resolved app data.
// Single source of truth for the dock SQL — invoked by build.sh `dock` and by the tester.
//
// Env in:
//   ORDER_J, PKGS_J, LABELS_J, COMPS_J  — JSON string-arrays, parallel by index
//   CONTAINER (hotseat container id), ITEM_TYPE, FLAGS (launchFlags), SLOTS (hotseat capacity)
// Out: SQL on stdout (BEGIN/DELETE/INSERT.../COMMIT); dropped-app warnings on stderr.
"use strict";
const q = s => "'" + String(s).replace(/'/g, "''") + "'";
const order = JSON.parse(process.env.ORDER_J);
const pkgs = JSON.parse(process.env.PKGS_J);
const labels = JSON.parse(process.env.LABELS_J);
const comps = JSON.parse(process.env.COMPS_J);
const C = process.env.CONTAINER, IT = process.env.ITEM_TYPE, FL = process.env.FLAGS;
const SLOTS = +process.env.SLOTS;

const idx = [...order.keys()].sort((a, b) => (+order[a]) - (+order[b]));
const out = ["BEGIN TRANSACTION;", `DELETE FROM favorites WHERE container=${C};`];
let slot = 0;
for (const k of idx) {
  if (slot >= SLOTS) { console.error(`WARN dock: ${pkgs[k]} dropped — only ${SLOTS} hotseat slots`); continue; }
  const intent = `#Intent;action=android.intent.action.MAIN;category=android.intent.category.LAUNCHER;` +
    `launchFlags=${FL};package=${pkgs[k]};component=${comps[k]};end`;
  out.push(
    `INSERT INTO favorites (title,intent,container,screen,cellX,cellY,spanX,spanY,itemType,` +
    `appWidgetId,modified,restored,profileId,rank,options,appWidgetSource) VALUES (` +
    `${q(labels[k])},${q(intent)},${C},${slot},${slot},0,1,1,${IT},-1,0,0,0,0,0,-1);`
  );
  slot++;
}
out.push("COMMIT;");
process.stdout.write(out.join("\n") + "\n");
