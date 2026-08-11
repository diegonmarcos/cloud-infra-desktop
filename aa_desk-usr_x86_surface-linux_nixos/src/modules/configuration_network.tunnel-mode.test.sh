#!/usr/bin/env bash
# Guard for the tunnel_mode toggle (configuration_network.nix).
#
# The toggle only works if ALL THREE consumers derive from tunnel_mode:
#   1. peer allowed-ips   2. ipv4/ipv6.never-default   3. dispatcher `wg set`
# Regressing any one of them back to a hardcoded literal makes the toggle
# silently half-apply, which is the exact failure mode this file exists to
# catch. ponytail: grep-level, not a nix eval — the 8GB Surface can't eval.
set -euo pipefail
cd "$(dirname "$0")"

NIX=configuration_network.nix
fail=0
ok()   { echo "  ok   — $1"; }
bad()  { echo "  FAIL — $1"; fail=1; }

# 1. both JSONs declare the field
for f in wireguard-endpoints.json wireguard-public-endpoints.json; do
  m=$(jq -r '.tunnel_mode // "MISSING"' "$f")
  case "$m" in
    split|full) ok "$f tunnel_mode=$m" ;;
    *)          bad "$f tunnel_mode is '$m' (want split|full)" ;;
  esac
done

# 2. no consumer bypasses the toggle
grep -q 'allowed-ips = wgTunnel.allowed4;'        "$NIX" && ok "wg0 allowed-ips derived"        || bad "wg0 allowed-ips not derived"
grep -q 'allowed-ips = wgPublicTunnel.allowed4;'  "$NIX" && ok "wg-public allowed-ips derived"  || bad "wg-public allowed-ips not derived"
grep -q 'wgTunnel.allowedBoth'                    "$NIX" && ok "wg0 dispatcher derived"         || bad "wg0 dispatcher not derived"
grep -q 'wgPublicTunnel.allowedBoth'              "$NIX" && ok "wg-public dispatcher derived"   || bad "wg-public dispatcher not derived"

if grep -qE 'never-default = "(true|false)"' "$NIX"; then
  bad "a hardcoded never-default survives — it must be wg{,Public}Tunnel.neverDefault"
else
  ok "all never-default values derived"
fi

n=$(grep -cE 'never-default = wg(Public)?Tunnel\.neverDefault' "$NIX")
[ "$n" -eq 4 ] && ok "4 never-default consumers wired" || bad "expected 4 never-default consumers, found $n"

# 3. the both-full footgun is guarded at eval time
grep -q 'wgTunnel.isFull && wgPublicTunnel.isFull' "$NIX" && ok "both-full assertion present" || bad "both-full assertion missing"

nix-instantiate --parse "$NIX" >/dev/null && ok "$NIX parses"

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
