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

  # IPv6 presence is decided by the MTU, not by preference. RFC8200 sets a hard
  # 1280 floor; below it the kernel disables IPv6 on the device outright, so a
  # declared wg_ipv6 is simply never assigned. wg0 sits at 1200 on purpose since
  # 2026-08-19 (._mtu_resolution_doc: chosen to stop TLS blackholing on clat
  # paths, lost v6 recorded as the accepted cost).
  #
  # This assertion used to be unconditional and had therefore been failing by
  # design ever since — reporting the documented trade-off as a fault, which is
  # how a suite teaches people to ignore it. Tie it to the mtu instead: absence
  # is correct below the floor, and required presence returns automatically the
  # moment someone restores 1280.
  local mtu; mtu=$(jq -r '.mtu' "$json")
  if [ "$mtu" -ge 1280 ] 2>/dev/null; then
    if ip -6 addr show "$iface" 2>/dev/null | grep -q "inet6 ${v6_expect}/"; then
      ok "$iface has expected IPv6 address $v6_expect (mtu $mtu)"
    else
      fail "$iface missing expected IPv6 address $v6_expect (mtu $mtu >= 1280 allows it)"
    fi
  else
    if ip -6 addr show "$iface" 2>/dev/null | grep -q "inet6 ${v6_expect}/"; then
      fail "$iface has $v6_expect but mtu $mtu < 1280 — kernel should have disabled v6"
    else
      ok "$iface has no IPv6, correct for mtu $mtu < 1280 (RFC8200 floor)"
    fi
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
mtu=$(jq -r '.mtu' "$WG_JSON")

has_listener() {
  grep -qE "^ListenAddress (\[)?${1}(\])?(:22)?\s*$" "$SSHD_CONF" 2>/dev/null
}

if has_listener "$v4"; then
  ok "sshd listens on wg0 $v4"
else
  fail "sshd does NOT listen on wg0 $v4 (no remote SSH at all)"
fi

# The v6 expectation follows the MTU, because the kernel does. Below RFC8200's
# 1280 floor IPv6 is disabled on the device entirely — no address, not even a
# link-local — so wg_ipv6 is declared in JSON but never assigned. See
# ._mtu_resolution_doc: 1200 was chosen on 2026-08-19 to stop TLS blackholing
# on clat paths, with the lost v6 recorded as the accepted cost.
#
# Asserting a v6 listener unconditionally would therefore fail forever by
# design. Asserting its ABSENCE while below the floor is the real invariant,
# and this flips to requiring it the moment someone restores 1280.
if [ "$mtu" -ge 1280 ] 2>/dev/null; then
  if has_listener "$v6"; then
    ok "sshd listens on wg0 $v6 (mtu $mtu >= 1280)"
  else
    fail "mtu $mtu allows IPv6 but sshd does not listen on wg0 $v6"
  fi
else
  if has_listener "$v6"; then
    fail "sshd binds $v6 but mtu $mtu < 1280 — kernel disables v6, address never exists"
  else
    ok "no v6 listener, correct for mtu $mtu < 1280 (RFC8200 floor, see _mtu_resolution_doc)"
  fi
fi

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
