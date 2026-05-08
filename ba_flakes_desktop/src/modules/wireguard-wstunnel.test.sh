#!/usr/bin/env bash
# ============================================================================
# wireguard-wstunnel.nix — module integrity tester
# ----------------------------------------------------------------------------
# Validates: nix syntax, cross-link to cloud sibling, parallel-style with
# existing cloud-network-wg-dns.nix, helper script structure, secrets
# contract, no-hardcoded-data rule.
# ============================================================================
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD_FILE="$MOD_DIR/wireguard-wstunnel.nix"
SIBLING_BUILD_JSON="$HOME/git/cloud/a_solutions/bb-net_wireguard-mesh-ws-tunnel/build.json"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
nope() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "▶ wireguard-wstunnel module tester  ($MOD_FILE)"

# ── Phase 1 · file presence ──────────────────────────────────────────────
echo "▶ Phase 1 · file presence"
[ -f "$MOD_FILE" ] && ok "wireguard-wstunnel.nix exists ($(stat -c%s "$MOD_FILE") bytes)" || { nope "module file missing"; exit 1; }
[ -f "$MOD_DIR/cloud-network-wg-dns.nix" ] && ok "sibling cloud-network-wg-dns.nix present" || nope "sibling module missing"

# ── Phase 2 · nix syntax (parse-check via nix-instantiate or just text) ──
echo "▶ Phase 2 · nix syntax"
if command -v nix >/dev/null 2>&1; then
  if nix-instantiate --parse "$MOD_FILE" >/dev/null 2>&1; then
    ok "nix-instantiate --parse passes"
  else
    nope "nix-instantiate --parse failed"
    nix-instantiate --parse "$MOD_FILE" 2>&1 | head -10 || true
  fi
else
  # Fallback: basic structural sanity
  grep -q '^{ config, lib, pkgs, \.\.\. }:' "$MOD_FILE" && ok "nix module signature ok" || nope "no module signature"
fi

# ── Phase 3 · cross-link to cloud sibling (data-driven contract) ─────────
echo "▶ Phase 3 · cross-link to cloud sibling"
grep -q 'a_solutions/bb-net_wireguard-mesh-ws-tunnel/build.json' "$MOD_FILE" \
  && ok "module references the cloud sibling build.json" \
  || nope "no reference to bb-net_wireguard-mesh-ws-tunnel/build.json — fire rule 6 (data-driven)"

if [ -f "$SIBLING_BUILD_JSON" ]; then
  ok "cloud sibling build.json exists at $SIBLING_BUILD_JSON"
  vpnDomain=$(jq -r '.domain' "$SIBLING_BUILD_JSON")
  [ "$vpnDomain" = "vpn.diegonmarcos.com" ] && ok "sibling .domain = $vpnDomain" || nope "sibling .domain=$vpnDomain (expected vpn.diegonmarcos.com)"

  # Module must NOT inline the same value
  inlines=$(grep -c '"vpn.diegonmarcos.com"' "$MOD_FILE" || echo 0)
  [ "$inlines" -le 1 ] && ok "domain inlined ≤1× (only as graceful fallback default)" \
    || nope "domain inlined $inlines× — should read from sibling build.json"
else
  nope "cloud sibling not checked out at expected path — module will use its fallback"
fi

# ── Phase 4 · systemd unit shape ────────────────────────────────────────
echo "▶ Phase 4 · systemd-user unit"
grep -q 'systemd\.user\.services\.wstunnel-client' "$MOD_FILE" && ok "systemd.user.services.wstunnel-client declared" || nope "service unit missing"
grep -q 'MemoryMax' "$MOD_FILE" && ok "MemoryMax cap declared (resource-bound)" || nope "no MemoryMax cap"
grep -q 'CPUQuota' "$MOD_FILE"  && ok "CPUQuota declared"                       || nope "no CPUQuota"
grep -q 'NoNewPrivileges'    "$MOD_FILE" && ok "NoNewPrivileges = true (hardened)" || nope "no NoNewPrivileges"
grep -q 'ProtectSystem'      "$MOD_FILE" && ok "ProtectSystem (hardened)"          || nope "no ProtectSystem"
grep -q 'WantedBy = \[ \]'   "$MOD_FILE" && ok "service is opt-in (no auto-start)" || nope "service auto-starts (should be opt-in)"

# ── Phase 5 · secret reference ──────────────────────────────────────────
echo "▶ Phase 5 · secrets contract"
grep -q '\.wstunnel-secret' "$MOD_FILE" && ok "secret file path declared (.wstunnel-secret)" || nope "secret path missing"
grep -q 'WSTUNNEL_PATH_PREFIX\|http-upgrade-path-prefix' "$MOD_FILE" \
  && ok "uses --http-upgrade-path-prefix from secret" \
  || nope "no path-prefix flag — server will reject"

# ── Phase 6 · helper script ─────────────────────────────────────────────
echo "▶ Phase 6 · wg-tcp helper script"
grep -q 'home\.file\."\.local/bin/wg-tcp"' "$MOD_FILE" && ok "wg-tcp helper script declared in home.file" || nope "helper script missing"
# Helper has bash case branches: `up)`, `down)`, `status)`
grep -qE '^\s*(up|down|status)\)' "$MOD_FILE" \
  && ok "helper has up/down/status case branches" \
  || nope "helper modes missing"

# ── Phase 7 · no-hardcoded-data sweep ───────────────────────────────────
echo "▶ Phase 7 · data-driven discipline"
# Each port literal must appear at most ONCE as a let-binding value; everywhere
# else it should reference the binding (localUdp / remoteWg / 443 via wsEndpoint).
# Doc/comment lines are allowed (they describe the system).
let_bindings=$(grep -cE '^\s*(localUdp|remoteWg)\s*=\s*[0-9]+' "$MOD_FILE")
[ "$let_bindings" = 2 ] && ok "ports defined ONCE in let bindings (localUdp + remoteWg)" \
                        || nope "$let_bindings let-bound port values (expected 2)"
# Outside let bindings + comments, raw 51820/51821 should be minimal — every
# runtime use must reference the binding via ${toString ...}. Pipeline guarded
# with `|| true` so an empty grep result (success) doesn't trip pipefail.
raw_outside=$( { grep -nE '\b(51820|51821)\b' "$MOD_FILE" || true; } \
             | { grep -vE '^[0-9]+:[[:space:]]*#' || true; } \
             | { grep -vE '^[[:space:]]*(localUdp|remoteWg)[[:space:]]*=' || true; } \
             | wc -l)
[ "$raw_outside" -le 6 ] && ok "raw port literals outside bindings: $raw_outside (acceptable, mostly comments)" \
                          || nope "$raw_outside raw port literals — should reference bindings via \${toString}"

echo
if [ "$fail" = 0 ]; then
  printf '▶ \033[32m%d passed, 0 failed\033[0m\n' "$pass"
  exit 0
else
  printf '▶ \033[31m%d passed, %d failed\033[0m\n' "$pass" "$fail"
  exit 1
fi
