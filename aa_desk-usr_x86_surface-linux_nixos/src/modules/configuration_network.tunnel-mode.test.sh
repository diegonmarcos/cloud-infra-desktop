#!/usr/bin/env bash
# Guard for the split/full tunnel toggle (configuration_network.nix).
#
# Split and full are two NM profiles on ONE interface, differing only in
# allowed-ips + never-default. The toggle only works if every consumer derives
# from the profile's `tunnel` argument rather than a hardcoded literal, and if
# the dispatcher keys off CONNECTION_ID (wg0 and wg0-full share an interface,
# so matching on IFACE alone re-applies split over full on every link-up).
# ponytail: grep-level, not a nix eval — the 8GB Surface can't eval.
set -euo pipefail
cd "$(dirname "$0")"

NIX=configuration_network.nix
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# 1. both JSONs declare the boot default
for f in wireguard-endpoints.json wireguard-public-endpoints.json; do
  m=$(jq -r '.tunnel_mode // "MISSING"' "$f")
  case "$m" in
    split|full) ok "$f tunnel_mode=$m" ;;
    *)          bad "$f tunnel_mode is '$m' (want split|full)" ;;
  esac
done

# 2. all four profiles exist
for p in '"wg0" = mkWg0Profile' '"wg0-full" = mkWg0Profile' \
         '"wg-public" = mkWgPublicProfile' '"wg-public-full" = mkWgPublicProfile'; do
  grep -qF "$p" "$NIX" && ok "profile ${p%% =*} declared" || bad "missing profile: ${p%% =*}"
done

# 3. no consumer bypasses the tunnel argument
n=$(grep -c 'allowed-ips = tunnel.allowed4;' "$NIX")
[ "$n" -eq 2 ] && ok "2 allowed-ips consumers derived" || bad "expected 2 derived allowed-ips, found $n"

n=$(grep -c 'never-default = tunnel.neverDefault;' "$NIX")
[ "$n" -eq 4 ] && ok "4 never-default consumers derived" || bad "expected 4 derived never-default, found $n"

if grep -qE 'never-default = "(true|false)"' "$NIX"; then
  bad "a hardcoded never-default survives — must be tunnel.neverDefault"
else
  ok "no hardcoded never-default"
fi

# 4. dispatcher keys on CONNECTION_ID and covers all four profiles
grep -q 'CONNECTION_ID' "$NIX" && ok "dispatcher keys on CONNECTION_ID" || bad "dispatcher still keys on IFACE only"
for id in wg0 wg0-full wg-public wg-public-full; do
  grep -qE "^ *$id\)" "$NIX" && ok "dispatcher handles $id" || bad "dispatcher missing case: $id"
done
for t in wgTunnel.allowedBoth wgTunnelFull.allowedBoth wgPublicTunnel.allowedBoth wgPublicTunnelFull.allowedBoth; do
  grep -qF "$t" "$NIX" && ok "dispatcher uses $t" || bad "dispatcher never uses $t"
done

# 5. footguns guarded
grep -q 'wgBootFull && wgPublicBootFull' "$NIX" && ok "both-boot-full assertion present" || bad "both-boot-full assertion missing"
grep -q 'wg-tunnel' "$NIX" && ok "wg-tunnel CLI shipped" || bad "wg-tunnel CLI missing"

nix-instantiate --parse "$NIX" >/dev/null && ok "$NIX parses"

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
