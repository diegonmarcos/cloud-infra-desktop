#!/usr/bin/env bash
# test-session-checkpoint.sh — proves a session checkpoint exists on disk.
#
# Per FIRE RULE 5: tester for configuration_session-checkpoint.nix.
# Data-driven: executes testers.checks from cloud-data-session-checkpoint.json.
# Run as root (sudo) — btrfs property/list need it.

set -u
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON="$MODULES_DIR/cloud-data-session-checkpoint.json"

PASS=0; FAIL=0
declare -a FAILED_TESTS=()
ok()   { echo "[OK]   $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }

n=$(jq '.testers.checks | length' "$JSON")
for i in $(seq 0 $((n - 1))); do
  id=$(jq -r ".testers.checks[$i].id" "$JSON")
  cmd=$(jq -r ".testers.checks[$i].command" "$JSON")
  expect=$(jq -r ".testers.checks[$i].expect // empty" "$JSON")
  regex=$(jq -r ".testers.checks[$i].expect_regex // empty" "$JSON")
  out=$(bash -c "$cmd" 2>/dev/null || true)
  if [ -n "$expect" ]; then
    if [ "$out" = "$expect" ]; then ok "$id"; else fail "$id (got '$out', want '$expect')"; fi
  elif [ -n "$regex" ]; then
    if echo "$out" | grep -Eq "$regex"; then ok "$id"; else fail "$id (got '$out', want regex '$regex')"; fi
  else
    fail "$id (no expectation declared in JSON)"
  fi
done

# Freshness: the newest checkpoint must be younger than 2× the interval —
# proves the timer is actually producing session files, not just that one
# ancient snapshot exists.
INTERVAL_MIN=$(jq -r '.checkpoint.interval_minutes' "$JSON")
SNAP_BASE="$(jq -r '.checkpoint.btrfs_root' "$JSON")/$(jq -r '.checkpoint.snapshot_dir' "$JSON")"
NEWEST=$(ls -1 "$SNAP_BASE" 2>/dev/null | sort | tail -1)
if [ -n "$NEWEST" ]; then
  AGE_S=$(( $(date +%s) - $(date -d "$(echo "$NEWEST" | tr 'T' ' ' | sed 's/-\([0-9][0-9]\)-\([0-9][0-9]\)Z/:\1:\2 UTC/')" +%s) ))
  MAX_S=$(( INTERVAL_MIN * 60 * 2 ))
  if [ "$AGE_S" -le "$MAX_S" ]; then
    ok "checkpoint_fresh (newest is ${AGE_S}s old, max ${MAX_S}s)"
  else
    fail "checkpoint_fresh (newest is ${AGE_S}s old, max ${MAX_S}s)"
  fi
else
  fail "checkpoint_fresh (no checkpoint found at $SNAP_BASE)"
fi

echo
echo "═══ RESULT: $PASS passed, $FAIL failed ═══"
[ $FAIL -gt 0 ] && { printf 'FAILED: %s\n' "${FAILED_TESTS[@]}"; exit 1; }
exit 0
