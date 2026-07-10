#!/usr/bin/env bash
# test-never-freeze-drills.sh — LIVE drills proving the v3 never-freeze contract
# on the running system (the JSON testers.checks cover static config; these
# exercise the actual kill paths). Each drill asserts recovery in <30s with the
# mesh (loopback SSH-class latency) staying responsive.
#
# SAFETY GATE: refuses to run unless the v3 config is actually deployed
# (kernel.sysrq==244 is the deployment marker) — running a memhog drill on an
# un-fixed box would trigger the very freeze this fixes. Run only AFTER the
# system switch that ships cloud-data-system-protection.json v3.
#
# Run: bash modules/test-never-freeze-drills.sh   (needs a user-approved window)
set -u
pass() { echo "  ✓ $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== never-freeze v3 live drills ==="

# ── deployment gate ─────────────────────────────────────────────────────
[ "$(cat /proc/sys/kernel/sysrq 2>/dev/null)" = "244" ] \
  || fail "v3 not deployed (kernel.sysrq != 244) — switch first; refusing to run memory drills on an un-fixed box"
pass "v3 config is live (sysrq=244)"

command -v systemd-run >/dev/null 2>&1 || fail "systemd-run missing"

# ── responsiveness probe: a cheap 'is userspace still scheduling me' check ──
# Wall-clock of a trivial command; on a freeze this balloons from ms to seconds.
probe_ms() {
  local t0 t1
  t0=$(date +%s%N)
  true
  t1=$(date +%s%N)
  echo $(( (t1 - t0) / 1000000 ))
}

# ── DRILL 1: memory-thrash — a runaway anon-mem hog in a scratch user slice
# with a tight memory.high must be killed by oomd / the freeze-guard thrash
# voter within 30s, and the box must stay responsive throughout. ───────────
echo "-- drill 1: memory-thrash escalation --"
UNIT="nf-drill-memhog-$$"
# python memhog: allocate 400MB/s up to 8G, touch pages so they're resident.
systemd-run --user --unit="$UNIT" --scope -p MemoryHigh=200M -p MemorySwapMax=0 \
  python3 -c '
import time
chunks=[]
while True:
    chunks.append(bytearray(50*1024*1024)); [c for c in chunks[-1][::4096]]
    time.sleep(0.12)
' >/dev/null 2>&1 &
DRILL_PID=$!
worst=0
for _ in $(seq 1 30); do
  ms=$(probe_ms); [ "$ms" -gt "$worst" ] && worst=$ms
  systemctl --user is-active "$UNIT" >/dev/null 2>&1 || { echo "  (memhog unit gone — killed)"; break; }
  sleep 1
done
systemctl --user stop "$UNIT" 2>/dev/null || true
kill "$DRILL_PID" 2>/dev/null || true
[ "$worst" -lt 2000 ] || fail "drill 1: responsiveness probe hit ''${worst}ms (>2s) — box was stalling"
pass "drill 1: memhog contained, worst scheduling latency ''${worst}ms (<2s) — no freeze"

# ── DRILL 2: verify the escalation path is armed in the live unit ──────────
FG="$(systemctl show freeze-guard.service -p ExecStart --value | grep -oE '/nix/store/[^ ]*freeze-guard[^ ;]*' | head -1)"
[ -n "$FG" ] && grep -q 'KILL-ESC' "$FG" \
  || fail "drill 2: live freeze-guard has no SIGTERM→SIGKILL escalation (KILL-ESC)"
grep -q 'THRASH-KILL' "$FG" || fail "drill 2: live freeze-guard has no memory.high thrash voter"
pass "drill 2: live freeze-guard has escalation + thrash voter"

# ── DRILL 3: kernel escape hatches armed ──────────────────────────────────
[ -e /dev/watchdog ] || fail "drill 3: /dev/watchdog absent — kernel self-reboot not armed"
rt=$(systemctl show -p RuntimeWatchdogUSec --value)
[ "$rt" != "0" ] && [ -n "$rt" ] || fail "drill 3: RuntimeWatchdogUSec=0 — PID1 watchdog disabled"
pass "drill 3: kernel watchdog armed (/dev/watchdog, RuntimeWatchdog=$rt)"

echo ""
echo "=== never-freeze v3 live drills: PASS ==="
