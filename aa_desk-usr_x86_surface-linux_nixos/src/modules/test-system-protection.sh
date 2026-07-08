#!/usr/bin/env bash
# test-system-protection.sh — proves the freeze-proof + data-driven contract.
#
# Per FIRE RULE 5: tester for configuration_system-protection.nix.
# Data-driven: executes testers.checks[] from cloud-data-system-protection.json
# (same runner pattern as test-session-checkpoint.sh). Each check proves one
# guarantee — the killers/mesh island, the swap valves, and (U1, PLAN-hardening
# §1C) that cpus/ramMB/rescue_port are DERIVED FROM THE JSON, not hardcoded.
# Run as root (sudo) is not required — all checks are `systemctl show` reads.

set -u
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON="$MODULES_DIR/cloud-data-system-protection.json"

PASS=0; FAIL=0
declare -a FAILED_TESTS=()
ok()   { echo "[OK]   $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }

# ── Generic checks-runner (mirrors test-session-checkpoint.sh) ─────────────
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

# ── U1 provenance cross-check: the SoT values feed the live system ─────────
# Proves the nix module read specs/rescue_port from THIS json (not an old
# hardcoded let-binding) by asserting the live daemon reflects the JSON value.
RP_JSON=$(jq -r '.rescue_port' "$JSON")
RP_LIVE=$(systemctl show rescue-ssh.service -p ExecStart --value 2>/dev/null | grep -oE -- '-p [0-9]+' | grep -oE '[0-9]+' || true)
if [ -n "$RP_LIVE" ] && [ "$RP_LIVE" = "$RP_JSON" ]; then
  ok "rescue_port_matches_json (live=$RP_LIVE == json=$RP_JSON)"
else
  fail "rescue_port_matches_json (live='$RP_LIVE' != json='$RP_JSON')"
fi

# CPUQuota on workload.slice must equal cpus×75% (cpus from JSON specs.cpu).
# systemd stores CPUQuotaPerSecUSec = period(1s) × quota. cpus*75% → cpus*0.75 s.
CPU_JSON=$(jq -r '.specs.cpu' "$JSON")
WANT_S="$(awk -v c="$CPU_JSON" 'BEGIN{printf "%g", c*0.75}')s"
GOT_S=$(systemctl show workload.slice -p CPUQuotaPerSecUSec --value 2>/dev/null || true)
if [ "$GOT_S" = "$WANT_S" ]; then
  ok "cpu_quota_matches_json_specs (workload.slice=$GOT_S == cpus($CPU_JSON)×75%)"
else
  fail "cpu_quota_matches_json_specs (got '$GOT_S', want '$WANT_S' from specs.cpu=$CPU_JSON)"
fi

echo
echo "═══ RESULT: $PASS passed, $FAIL failed ═══"
[ $FAIL -gt 0 ] && { printf 'FAILED: %s\n' "${FAILED_TESTS[@]}"; exit 1; }
exit 0
