#!/usr/bin/env bash
# ============================================================================
# wireguard-wstunnel.nix — termux module integrity tester
# ----------------------------------------------------------------------------
# Sibling of ~/git/cloud-infra-desktop/ba_flakes_desktop/src/modules/wireguard-wstunnel.test.sh
#
# Validates: nix syntax, cross-link to cloud sibling, helper script shape,
# secrets contract, no-hardcoded-data discipline, termux-specific
# differences (foreground process via PID file, not systemd-user).
# ============================================================================
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD_FILE="$MOD_DIR/wireguard-wstunnel.nix"
SIBLING_BUILD_JSON="$HOME/git/cloud-infra/a_solutions/bb-net_wireguard-mesh-ws-tunnel/build.json"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
nope() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "▶ wireguard-wstunnel termux module tester  ($MOD_FILE)"

# ── Phase 1 · file presence ──────────────────────────────────────────────
echo "▶ Phase 1 · file presence"
[ -f "$MOD_FILE" ] && ok "wireguard-wstunnel.nix exists ($(stat -c%s "$MOD_FILE") bytes)" || { nope "module file missing"; exit 1; }
[ -f "$MOD_DIR/wireguard.nix" ] && ok "sibling wireguard.nix present" || nope "sibling wireguard.nix missing"

# ── Phase 2 · nix syntax ─────────────────────────────────────────────────
echo "▶ Phase 2 · nix syntax"
if command -v nix >/dev/null 2>&1; then
  if nix-instantiate --parse "$MOD_FILE" >/dev/null 2>&1; then
    ok "nix-instantiate --parse passes"
  else
    nope "nix-instantiate --parse failed"
    nix-instantiate --parse "$MOD_FILE" 2>&1 | head -10 || true
  fi
else
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
  [ "$vpnDomain" = "vpn.diegonmarcos.com" ] && ok "sibling .domain = $vpnDomain" || nope "sibling .domain=$vpnDomain"

  # Module must NOT inline the same value
  inlines=$(grep -c '"vpn.diegonmarcos.com"' "$MOD_FILE" || echo 0)
  [ "$inlines" -le 1 ] && ok "domain inlined ≤1× (only as graceful fallback default)" \
    || nope "domain inlined $inlines× — should read from sibling build.json"
else
  nope "cloud sibling not checked out — module will use its fallback"
fi

# ── Phase 4 · termux-specific shape (NO systemd-user) ────────────────────
echo "▶ Phase 4 · termux specifics"
grep -q 'systemd\.user\.services' "$MOD_FILE" \
  && nope "termux module declares systemd.user.services — nix-on-droid has no systemd-user" \
  || ok "no systemd.user.services declaration (correct for termux)"
# wstunnel must run via the helper, not as a unit — verify wstunnel exec
# happens INSIDE the helper script body
grep -q '\${wstunnelBin}.*client' "$MOD_FILE" \
  && ok "wstunnel client invocation present in helper script" \
  || nope "no wstunnel client invocation in module"
# Termux uses wake-lock; helper must mention it (advisory)
grep -q 'termux-wake-lock' "$MOD_FILE" \
  && ok "helper warns about termux-wake-lock (Android lifecycle)" \
  || nope "no termux-wake-lock advisory — backgrounded wstunnel will die"

# ── Phase 5 · secret reference ───────────────────────────────────────────
echo "▶ Phase 5 · secrets contract"
grep -q '\.wstunnel-secret' "$MOD_FILE" && ok "secret file path declared (.wstunnel-secret)" || nope "secret path missing"
grep -q 'restrict-http-upgrade-path-prefix' "$MOD_FILE" \
  && ok "uses --restrict-http-upgrade-path-prefix flag (matches wstunnel v10.5.4+)" \
  || nope "no --restrict-http-upgrade-path-prefix flag — server will reject"

# ── Phase 6 · helper script ──────────────────────────────────────────────
echo "▶ Phase 6 · wg-tcp helper script"
grep -q 'home\.file\."\.local/bin/wg-tcp"' "$MOD_FILE" && ok "wg-tcp helper script declared in home.file" || nope "helper script missing"
# Helper has up/down/status case branches
grep -qE '^\s*(up|down|status)\)' "$MOD_FILE" \
  && ok "helper has up/down/status case branches" \
  || nope "helper modes missing"
# Helper records PID file (no systemd, manual lifecycle)
grep -qE 'PIDFILE|pid.file|\.wstunnel\.pid' "$MOD_FILE" \
  && ok "helper uses PID file for foreground-process lifecycle" \
  || nope "no PID-file mechanism — termux helper can't track wstunnel"

# ── Phase 7 · data-driven discipline ─────────────────────────────────────
echo "▶ Phase 7 · data-driven discipline"
let_bindings=$(grep -cE '^\s*(localUdp|remoteWg)\s*=\s*[0-9]+' "$MOD_FILE")
[ "$let_bindings" = 2 ] && ok "ports defined ONCE in let bindings (localUdp + remoteWg)" \
                        || nope "$let_bindings let-bound port values (expected 2)"
raw_outside=$( { grep -nE '\b(51820|51821)\b' "$MOD_FILE" || true; } \
             | { grep -vE '^[0-9]+:[[:space:]]*#' || true; } \
             | { grep -vE '^[[:space:]]*(localUdp|remoteWg)[[:space:]]*=' || true; } \
             | wc -l)
[ "$raw_outside" -le 6 ] && ok "raw port literals outside bindings: $raw_outside (acceptable)" \
                          || nope "$raw_outside raw port literals — should reference bindings via \${toString}"

echo
if [ "$fail" = 0 ]; then
  printf '▶ \033[32m%d passed, 0 failed\033[0m\n' "$pass"
  exit 0
else
  printf '▶ \033[31m%d passed, %d failed\033[0m\n' "$pass" "$fail"
  exit 1
fi
