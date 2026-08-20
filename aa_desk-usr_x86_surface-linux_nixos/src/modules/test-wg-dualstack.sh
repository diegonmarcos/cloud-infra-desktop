#!/usr/bin/env bash
# test-wg-dualstack.sh — proves both wg0 and wg-public NetworkManager profiles
# came up dual-stack (a v4 AND a v6 address present on each interface).
#
# Per FIRE RULE 5: every solution needs a tester. Companion to the 2026-07-26
# dual-stack work in wireguard-endpoints.json / wireguard-public-endpoints.json
# / configuration_network.nix.
#
# Run AFTER `build.sh r` (switch) with both meshes connected. Returns 0 if
# both interfaces are dual-stack, non-zero otherwise.

set -u
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0
declare -a FAILED_TESTS=()
ok()   { echo "[OK]   $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }

check_dualstack() {
  local iface="$1" json="$2"
  local v4_expect v6_expect
  v4_expect=$(jq -r '.client.wg_ip' "$json")
  v6_expect=$(jq -r '.client.wg_ipv6' "$json")

  if ip -4 addr show "$iface" 2>/dev/null | grep -q "inet ${v4_expect}/"; then
    ok "$iface has expected IPv4 address $v4_expect"
  else
    fail "$iface missing expected IPv4 address $v4_expect"
  fi

  if ip -6 addr show "$iface" 2>/dev/null | grep -q "inet6 ${v6_expect}/"; then
    ok "$iface has expected IPv6 address $v6_expect"
  else
    fail "$iface missing expected IPv6 address $v6_expect"
  fi
}

echo "═══ wg0 dual-stack ═══"
check_dualstack "wg0" "$MODULES_DIR/wireguard-endpoints.json"

echo "═══ wg-public dual-stack ═══"
check_dualstack "wg-public" "$MODULES_DIR/wireguard-public-endpoints.json"

# ── sshd binds BOTH families of wg0, and still nothing else ──────────────
# A dual-stack interface is only half the job: sshd bound wg0's v4 address
# alone, so a peer arriving over the v6 mesh found nothing listening while
# every check above still passed. Same class of failure galaxy hit on
# 2026-08-20 — one address hardcoded where the interface carries several.
echo "═══ sshd bind policy ═══"
WG_JSON="$MODULES_DIR/wireguard-endpoints.json"
SSHD_CONF=/etc/ssh/sshd_config
v4=$(jq -r '.client.wg_ip'   "$WG_JSON")
v6=$(jq -r '.client.wg_ipv6' "$WG_JSON")

for a in "$v4" "$v6"; do
  if grep -qE "^ListenAddress (\[)?${a}(\])?(:22)?\s*$" "$SSHD_CONF" 2>/dev/null; then
    ok "sshd listens on wg0 $a"
  else
    fail "sshd does NOT listen on wg0 $a (peers on that family cannot reach us)"
  fi
done

# The 2026-06-15 owner decision is "SSH only on wg0, no public". A wildcard or
# a wg-public address here would silently revoke it, so assert the negative.
if grep -qE '^ListenAddress (0\.0\.0\.0|::|\*)' "$SSHD_CONF" 2>/dev/null; then
  fail "sshd has a WILDCARD ListenAddress — LAN/public exposure"
else
  ok "no wildcard ListenAddress (wg0-only policy intact)"
fi

if grep -qE '^ListenAddress (\[)?(10\.1\.0\.|fd0c:1d01)' "$SSHD_CONF" 2>/dev/null; then
  fail "sshd listens on wg-public — contradicts 'SSH only on wg0, no public'"
else
  ok "wg-public not bound (owner decision preserved)"
fi

echo
echo "═══ RESULT: $PASS passed, $FAIL failed ═══"
if [ $FAIL -gt 0 ]; then
  printf 'FAILED: %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
exit 0
