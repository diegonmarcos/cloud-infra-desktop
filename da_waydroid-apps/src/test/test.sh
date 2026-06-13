#!/usr/bin/env bash
# waydroid-apps — tester. Proves the declarative/data-driven contract.
# Pure tests run anywhere (no Waydroid needed). Live tests run only if a session is up.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="$ROOT/build.json"
LOCKFILE="$ROOT/src/apps.lock.json"
APK_DIR="$ROOT/dist/apks"
pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

echo "== T1: build.json is valid JSON and every app has package+source+group =="
if node -e "
  const c=require('$CONFIG');
  if(!Array.isArray(c.apps)||!c.apps.length) throw 'no apps';
  for(const a of c.apps){ if(!a.package||!a.source||!a.source.type||!a.group) throw 'bad app '+JSON.stringify(a); }
"; then ok "schema"; else no "schema"; fi

echo "== T2: dock_order values are unique and contiguous from 1 =="
if node -e "
  const c=require('$CONFIG');
  const d=c.apps.map(a=>a.dock_order).filter(x=>x!=null).sort((a,b)=>a-b);
  const set=new Set(d); if(set.size!==d.length) throw 'duplicate dock_order';
  for(let i=0;i<d.length;i++){ if(d[i]!==i+1) throw 'dock_order not contiguous from 1: '+d; }
"; then ok "dock_order 1..N unique"; else no "dock_order"; fi

echo "== T3: SuperApp is leftmost (dock_order=1), IDE group precedes comms group =="
if node -e "
  const c=require('$CONFIG');
  const docked=c.apps.filter(a=>a.dock_order!=null).sort((a,b)=>a.dock_order-b.dock_order);
  if(docked[0].group!=='core') throw 'leftmost not core: '+docked[0].package;
  const grp=docked.map(a=>a.group);
  const firstComms=grp.indexOf('comms'), lastIde=grp.lastIndexOf('ide');
  if(lastIde>-1&&firstComms>-1&&lastIde>firstComms) throw 'ide after comms';
"; then ok "order core -> ide -> comms"; else no "group order"; fi

echo "== T4: lockfile (if present) matches build.json remote apps =="
if [ -f "$LOCKFILE" ]; then
  if node -e "
    const c=require('$CONFIG'), l=require('$LOCKFILE');
    const want=c.apps.filter(a=>['fdroid','github'].includes(a.source.type)).map(a=>a.package).sort();
    const have=l.apps.map(a=>a.package).sort();
    if(JSON.stringify(want)!==JSON.stringify(have)) throw 'drift '+JSON.stringify({want,have});
    for(const a of l.apps){ if(!/^sha256-/.test(a.sha256)) throw 'bad hash '+a.package; if(!/^https:/.test(a.url)) throw 'bad url '+a.package; }
  "; then ok "lockfile consistent + SRI hashes"; else no "lockfile"; fi
else echo "  (skip — no lockfile yet; run ./build.sh lock)"; fi

echo "== T5: dock SQL generator (shared lib) escapes quotes and respects slot cap =="
GEN="$ROOT/src/lib/gen-dock-sql.js"
out="$(CONTAINER=-101 ITEM_TYPE=0 FLAGS=0x10200000 SLOTS=2 \
  ORDER_J='["1","2","3"]' \
  PKGS_J='["a.b","c.d","e.f"]' \
  LABELS_J='["O'\''Brien","Two","Three"]' \
  COMPS_J='["a.b/.M","c.d/.M","e.f/.M"]' \
  node "$GEN" 2>/tmp/wda_t5.err)"
inserts="$(printf '%s\n' "$out" | grep -c '^INSERT')"
if [ "$inserts" -eq 2 ] && printf '%s' "$out" | grep -q "O''Brien" && grep -q 'dropped' /tmp/wda_t5.err; then
  ok "SQL escaping + slot cap (3 docked, 2 slots -> 2 INSERTs, quote doubled, 1 dropped)"
else no "SQL generator (inserts=$inserts err=$(cat /tmp/wda_t5.err))"; fi

echo "== T6 (live): every declared APK is installable / present =="
if waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING'; then
  missing=0
  while read -r pkg; do
    [ -f "$APK_DIR/$pkg.apk" ] || { echo "    missing APK: $pkg"; missing=1; }
  done < <(node -e "require('$CONFIG').apps.forEach(a=>console.log(a.package))")
  [ "$missing" -eq 0 ] && ok "all APKs built" || no "some APKs not built (run ./build.sh build)"
else echo "  (skip — no live Waydroid session)"; fi

echo
echo "Total: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
