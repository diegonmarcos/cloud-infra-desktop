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

echo
echo "═══ RESULT: $PASS passed, $FAIL failed ═══"
if [ $FAIL -gt 0 ]; then
  printf 'FAILED: %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
exit 0
