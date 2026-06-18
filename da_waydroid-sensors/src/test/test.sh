#!/usr/bin/env bash
# waydroid-sensors — tester. Pure tests run anywhere; live tests need a Waydroid session.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="$ROOT/build.json"
CONF="$ROOT/$(node -e "process.stdout.write(require('$CONFIG').paths.conf)")"
BIN="$ROOT/dist/$(node -e "process.stdout.write(require('$CONFIG').paths.binary)")"
pass=0; fail=0
ok(){ printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

echo "== T1: build.json schema (iio.name, poll, mount axes valid, binder.device) =="
if node -e "
  const c=require('$CONFIG');
  if(!c.iio||!c.iio.name) throw 'no iio.name';
  if(!(c.iio.poll_interval_ms>0)) throw 'bad poll';
  for(const a of ['x','y','z']){const m=c.iio.mount[a];
    if(!m||!['x','y','z'].includes(m.src)) throw 'bad mount.'+a+'.src';
    if(![1,-1].includes(m.sign)) throw 'bad mount.'+a+'.sign';}
  if(!c.binder||!/^\\/dev\\//.test(c.binder.device)) throw 'bad binder.device';
"; then ok "schema"; else no "schema"; fi

echo "== T2: mount matrix is a permutation (each raw axis used exactly once) =="
if node -e "
  const m=require('$CONFIG').iio.mount;
  const used=[m.x.src,m.y.src,m.z.src].sort().join('');
  if(used!=='xyz') throw 'mount not a permutation of x,y,z: '+used;
"; then ok "mount permutation"; else no "mount permutation (axes must each map once)"; fi

echo "== T3: conf renders with all daemon keys =="
( cd "$ROOT" && ./build.sh conf >/dev/null 2>&1 ) || true
if [ -f "$CONF" ] && node -e "
  const t=require('fs').readFileSync('$CONF','utf8');
  for(const k of ['IIO_NAME','POLL_INTERVAL_MS','POLL_WAIT_MS','AXIS_X_SRC','AXIS_X_SIGN','AXIS_Y_SRC','AXIS_Z_SIGN'])
    if(!new RegExp('^'+k+'=','m').test(t)) throw 'missing '+k;
"; then ok "conf render"; else no "conf render"; fi

echo "== T4: source layout — upstream gbinder layer present + IIO source ours =="
miss=0
for f in src/code/Sensors.cpp src/code/service.cpp src/code/hybrisbindertypes.h src/code/SensorFW.cpp src/code/SensorFW.h src/code/CMakeLists.txt src/flake.nix; do
  [ -f "$ROOT/$f" ] || { echo "    missing $f"; miss=1; }
done
# SensorFW.cpp must be the IIO version (reads /sys/bus/iio), not the sensorfw one
if [ "$miss" -eq 0 ] && grep -q "/sys/bus/iio" "$ROOT/src/code/SensorFW.cpp"; then ok "layout + IIO source"; else no "layout/IIO source"; fi

echo "== T5: host has the configured IIO accelerometer =="
name="$(node -e "process.stdout.write(require('$CONFIG').iio.name)")"
found=0
for d in /sys/bus/iio/devices/iio:device*; do
  [ -r "$d/name" ] || continue
  if [ "$(cat "$d/name" 2>/dev/null)" = "$name" ] && [ -r "$d/in_accel_x_raw" ]; then found=1; break; fi
done
[ "$found" -eq 1 ] && ok "host IIO '$name' present" || no "host IIO '$name' not found"

echo "== T6 (build): daemon binary built =="
[ -x "$BIN" ] && ok "daemon built ($BIN)" || echo "  (skip — run ./build.sh build)"

echo "== T7 (live): Android sees an accelerometer =="
if waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING'; then
  WDSH=(waydroid); waydroid shell -- true >/dev/null 2>&1 || WDSH=(sudo waydroid)
  dump="$("${WDSH[@]}" shell -- dumpsys sensorservice 2>/dev/null | tr -d '\r')"
  if printf '%s' "$dump" | grep -qi 'accelerometer'; then ok "accelerometer present in sensorservice"
  elif printf '%s' "$dump" | grep -qi 'No Sensors'; then no "still 'No Sensors' (daemon not bound — run enable/takeover)"
  else echo "  (inconclusive — sensorservice output unexpected)"; fi
else echo "  (skip — no live Waydroid session)"; fi

echo "== T8: boot-safety — poll() bounded by data-driven POLL_WAIT_MS (no forever-loop) =="
# Guards the regression that hung Android boot: SensorService issues a blocking poll()
# during init; an unbounded wait there deadlocks system_server. The bound + empty-batch
# fallback must stay wired across build.json, SensorFW, Sensors and service.cpp.
if node -e "
    const t=require('$CONFIG').timeouts||{};
    if(!Number.isInteger(t.poll_wait_ms)) throw 'timeouts.poll_wait_ms missing/not int';
    if(!(t.poll_wait_ms>0&&t.poll_wait_ms<=10000)) throw 'poll_wait_ms out of (0,10000]: '+t.poll_wait_ms;
  " \
  && grep -q 'POLL_WAIT_MS' "$ROOT/src/code/SensorFW.cpp" \
  && grep -q 'GetPollWaitMs' "$ROOT/src/code/Sensors.cpp" \
  && grep -Eq 'g_timeout_add\(.*pollWaitMs' "$ROOT/src/code/Sensors.cpp" \
  && grep -q 'poll_timeout_cb' "$ROOT/src/code/Sensors.cpp" \
  && ! grep -Eq '&event_vec\[0\]|&sensors_vec\[0\]' "$ROOT/src/code/service.cpp"
then ok "poll() bounded + empty-batch fallback wired end-to-end"
else no "poll() boot-safety wiring missing (forever-loop regression risk)"; fi

echo
echo "Total: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
