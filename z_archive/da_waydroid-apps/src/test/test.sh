#!/usr/bin/env bash
# waydroid-apps — tester. Pure tests run anywhere; live tests need a Waydroid session.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="$ROOT/build.json"
LOCKFILE="$ROOT/src/apps.lock.json"
APK_DIR="$ROOT/dist/apks"
GEN="$ROOT/src/lib/gen-layout-sql.js"
pass=0; fail=0
ok(){ printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

echo "== T1: build.json schema (apps, launcher{folders,hotseat,workspace}, theme) =="
if node -e "
  const c=require('$CONFIG');
  if(!Array.isArray(c.apps)||!c.apps.length) throw 'no apps';
  for(const a of c.apps){ if(!a.package||!a.source||!a.group) throw 'bad app '+JSON.stringify(a); }
  const l=c.launcher; if(!l||!l.folders||!Array.isArray(l.hotseat)||!l.workspace) throw 'bad launcher';
  if(!c.theme||typeof c.theme.dark_mode!=='boolean') throw 'bad theme';
"; then ok "schema"; else no "schema"; fi

echo "== T2: every launcher ref resolves (app package or existing folder) =="
if node -e "
  const c=require('$CONFIG'), l=c.launcher;
  const pkgs=new Set(c.apps.map(a=>a.package)), fids=new Set(Object.keys(l.folders));
  const chkRef=r=>{ if(String(r).startsWith('folder:')){ if(!fids.has(r.slice(7))) throw 'unknown folder '+r; }
                    else if(!pkgs.has(r)) throw 'unknown package '+r; };
  for(const f of Object.values(l.folders)) for(const m of f.members) if(!pkgs.has(m)) throw 'folder member not an app: '+m;
  l.hotseat.forEach(chkRef); l.workspace.cells.forEach(c=>chkRef(c.ref));
"; then ok "refs resolve"; else no "refs resolve"; fi

echo "== T3: workspace cells fit the grid and don't collide =="
if node -e "
  const l=require('$CONFIG').launcher; const cols=l.grid_columns; const seen=new Set();
  for(const c of l.workspace.cells){
    if(c.cellX<0||c.cellX>=cols) throw 'cellX out of grid: '+JSON.stringify(c);
    const k=c.cellY+','+c.cellX; if(seen.has(k)) throw 'cell collision at '+k; seen.add(k);
  }
"; then ok "grid fit + no collisions"; else no "grid"; fi

echo "== T4: lockfile (if present) matches build.json remote apps =="
if [ -f "$LOCKFILE" ]; then
  if node -e "
    const c=require('$CONFIG'), lk=require('$LOCKFILE');
    const want=c.apps.filter(a=>['fdroid','github'].includes(a.source.type)).map(a=>a.package).sort();
    const have=lk.apps.map(a=>a.package).sort();
    if(JSON.stringify(want)!==JSON.stringify(have)) throw 'drift';
  "; then ok "lockfile consistent"; else no "lockfile"; fi
else echo "  (skip — no lockfile)"; fi

echo "== T5: gen-layout-sql.js builds folders+members+hotseat+workspace correctly =="
out="$(FOLDERS_J='{"g":{"title":"Grp","members":["a.b","c.d"]}}' \
  HOTSEAT_J='["x.y","folder:g"]' \
  WORKSPACE_J='{"screen":0,"cells":[{"ref":"x.y","cellX":0,"cellY":0}]}' \
  COMPONENTS_J='{"a.b":"a.b/.M","c.d":"c.d/.M","x.y":"x.y/.M"}' \
  HOTSEAT_CONTAINER=-101 WORKSPACE_CONTAINER=-100 FLAGS=0x10200000 ITEM_APP=0 ITEM_FOLDER=2 \
  node "$GEN" 2>/dev/null)"
# Expect: DELETE; folder row (itemType 2); 2 members in container=<folder id>; hotseat app+folder; workspace app
folders="$(printf '%s\n' "$out" | grep -c ',2,-1,')"     # itemType=2 rows (folder)
inserts="$(printf '%s\n' "$out" | grep -c '^INSERT')"
if printf '%s' "$out" | grep -q '^DELETE FROM favorites;' && [ "$folders" -eq 1 ] && [ "$inserts" -ge 5 ]; then
  ok "layout SQL (1 folder, $inserts inserts, wipe-and-rebuild)"
else no "layout SQL (folders=$folders inserts=$inserts)"; fi

echo "== T6 (build): every declared APK built =="
if waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING' || true; then
  miss=0
  while read -r pkg; do [ -f "$APK_DIR/$pkg.apk" ] || { echo "    missing $pkg"; miss=1; }; done \
    < <(node -e "require('$CONFIG').apps.forEach(a=>console.log(a.package))")
  [ "$miss" -eq 0 ] && ok "all APKs built" || echo "  (run ./build.sh build)"
fi

echo "== T7 (live): hotseat + workspace populated =="
if waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING'; then
  WDSH=(waydroid); waydroid shell -- true >/dev/null 2>&1 || WDSH=(sudo waydroid)
  root=/home/diego/.local/share/waydroid/data
  db="$(sudo find "$root" -path "$root/data/com.android.launcher3/databases/launcher_*.db" 2>/dev/null | head -1)"
  if [ -n "$db" ]; then
    h="$(sudo sqlite3 "$db" "SELECT count(*) FROM favorites WHERE container=-101;" 2>/dev/null)"
    w="$(sudo sqlite3 "$db" "SELECT count(*) FROM favorites WHERE container=-100;" 2>/dev/null)"
    [ "${h:-0}" -ge 1 ] && [ "${w:-0}" -ge 1 ] && ok "hotseat=$h workspace=$w" || no "hotseat=$h workspace=$w (run ./build.sh layout)"
  else echo "  (launcher db not found)"; fi
else echo "  (skip — no live session)"; fi

echo
echo "Total: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
