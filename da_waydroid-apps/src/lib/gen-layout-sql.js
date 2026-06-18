#!/usr/bin/env node
// Generate the full Launcher3 `favorites` layout SQL from the data-driven `launcher`
// block in build.json. Single source of truth for the layout; invoked by build.sh `layout`
// and by the tester. Wipes favorites and rebuilds: folders (itemType=2), hotseat
// (container=-101), workspace (container=-100), and folder members (container=<folder _id>).
//
// Env in (all JSON):
//   FOLDERS_J     {id: {title, members:[pkg]}}
//   HOTSEAT_J     [ref]                          ref = pkg | "folder:<id>"
//   WORKSPACE_J   {screen, cells:[{ref,cellX,cellY}]}
//   COMPONENTS_J  {pkg: "<pkg>/<activity>"}      resolved LAUNCHER activities
//   HOTSEAT_CONTAINER, WORKSPACE_CONTAINER, FLAGS, ITEM_APP, ITEM_FOLDER
// Out: SQL on stdout; warnings (skipped refs) on stderr.
"use strict";
const q = s => "'" + String(s).replace(/'/g, "''") + "'";
const folders = JSON.parse(process.env.FOLDERS_J);
const hotseat = JSON.parse(process.env.HOTSEAT_J);
const workspace = JSON.parse(process.env.WORKSPACE_J);
const comp = JSON.parse(process.env.COMPONENTS_J);
const HC = process.env.HOTSEAT_CONTAINER, WC = process.env.WORKSPACE_CONTAINER;
const FL = process.env.FLAGS, IT_APP = process.env.ITEM_APP, IT_FOLDER = process.env.ITEM_FOLDER;

let id = 0;
const out = ["BEGIN TRANSACTION;", "DELETE FROM favorites;"];

const COLS = "(_id,title,intent,container,screen,cellX,cellY,spanX,spanY,itemType," +
             "appWidgetId,modified,restored,profileId,rank,options,appWidgetSource)";
const intentFor = pkg =>
  `#Intent;action=android.intent.action.MAIN;category=android.intent.category.LAUNCHER;` +
  `launchFlags=${FL};package=${pkg};component=${comp[pkg]};end`;

function appRow(pkg, container, screen, cellX, cellY, rank) {
  const _id = ++id;
  out.push(`INSERT INTO favorites ${COLS} VALUES (${_id},${q(pkg)},${q(intentFor(pkg))},` +
    `${container},${screen},${cellX},${cellY},1,1,${IT_APP},-1,0,0,0,${rank|0},0,-1);`);
  return _id;
}
function folderRow(def, container, screen, cellX, cellY) {
  const _id = ++id;
  out.push(`INSERT INTO favorites ${COLS} VALUES (${_id},${q(def.title)},NULL,` +
    `${container},${screen},${cellX},${cellY},1,1,${IT_FOLDER},-1,0,0,0,0,0,-1);`);
  // members live inside the folder (container = folder _id), ordered by rank
  let rank = 0;
  for (const m of def.members) {
    if (!comp[m]) { console.error(`WARN layout: folder '${def.title}' member ${m} unresolved — skipped`); continue; }
    appRow(m, _id, 0, 0, 0, rank++);
  }
  return _id;
}
function place(ref, container, screen, cellX, cellY) {
  if (ref.startsWith("folder:")) {
    const fid = ref.slice(7); const def = folders[fid];
    if (!def) { console.error(`WARN layout: unknown folder ${fid} — skipped`); return; }
    folderRow(def, container, screen, cellX, cellY);
  } else {
    if (!comp[ref]) { console.error(`WARN layout: ${ref} unresolved (installed?) — skipped`); return; }
    appRow(ref, container, screen, cellX, cellY, 0);
  }
}

// hotseat (bottom bar): left→right, screen=slot, cellX=slot
hotseat.forEach((ref, slot) => place(ref, HC, slot, slot, 0));
// workspace (home screens): each cell may override `screen` (0 = first page,
// 1 = second page, …); default to workspace.screen. This is what puts the phone
// apps on a separate home page from the constellation apps.
for (const c of workspace.cells) place(c.ref, WC, (c.screen ?? workspace.screen), c.cellX, c.cellY);

out.push("COMMIT;");
process.stdout.write(out.join("\n") + "\n");
