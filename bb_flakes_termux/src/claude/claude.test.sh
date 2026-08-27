#!/usr/bin/env bash
# ============================================================================
# claude.test.sh — SoT-staleness tester
# ----------------------------------------------------------------------------
# The bug this guards: bb_flakes_termux used to consume da_my-ai's Claude
# settings through a PINNED flake input (`my-ai = { url =
# "github:diegonmarcos/cloud-u-linux?dir=da_my-ai"; }`). The lock sat stale
# 2026-08-18 to 2026-08-20 while `cleanupPeriodDays: 36500` landed in
# settings.base.json — the phone silently deployed pre-fix settings for two
# days, on Claude Code's built-in 30-day transcript retention, the exact
# mechanism that then swept ~2.5 months of session history.
#
# The fix: claude.nix now reads da_my-ai/src/data/claude straight from the
# WORKING CHECKOUT at activation time (assets/scripts/claude-settings-merge.sh
# + claude-assets-deploy.sh), never through a flake input. This test:
#   1. proves the merge script actually carries a SoT-only key through to the
#      deployed file (synthetic fixture — mutation-tested during development),
#   2. proves the REAL SoT + the REAL termux overlay, merged with the REAL
#      script, produce a deployed settings.json with a real cleanupPeriodDays
#      — the direct "would this catch 2026-08-18..20 again?" assertion,
#   3. proves the pinned-input trap itself cannot come back (no `my-ai` flake
#      input, no `claudeSrc` module arg).
#
# Runs offline once the repo is checked out. Never touches the real
# ~/.claude — everything happens in a sandbox dir.
# ============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_SCRIPT="$DIR/assets/scripts/claude-settings-merge.sh"
DEPLOY_SCRIPT="$DIR/assets/scripts/claude-assets-deploy.sh"
FLAKE_NIX="$DIR/../flake.nix"
CLAUDE_NIX="$DIR/claude.nix"
REAL_SOT="$DIR/../../../da_my-ai/src/data/claude"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
nope() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "▶ claude.test.sh — SoT-staleness tester"

[ -f "$MERGE_SCRIPT" ]  || { nope "claude-settings-merge.sh missing"; exit 1; }
[ -f "$DEPLOY_SCRIPT" ] || { nope "claude-assets-deploy.sh missing"; exit 1; }
command -v jq >/dev/null 2>&1  || { echo "  jq required"; exit 1; }
command -v sed >/dev/null 2>&1 || { echo "  sed required"; exit 1; }
bash -n "$MERGE_SCRIPT"  && ok "claude-settings-merge.sh: bash syntax" || nope "claude-settings-merge.sh: bash syntax"
bash -n "$DEPLOY_SCRIPT" && ok "claude-assets-deploy.sh: bash syntax"  || nope "claude-assets-deploy.sh: bash syntax"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

run_merge() {
  # args: REPO_SOT OVERLAY DST
  REPO_SOT="$1" OVERLAY="$2" DST="$3" HOME_DIR="$SANDBOX/home" \
    bash "$MERGE_SCRIPT"
}

# ── Phase 1 · synthetic fixture — a key present ONLY in the SoT must survive ─
echo "▶ Phase 1 · synthetic SoT -> deployed settings"
FIXTURE="$SANDBOX/fixture-sot"
mkdir -p "$FIXTURE"
cat > "$FIXTURE/settings.base.json" <<'EOF'
{"cleanupPeriodDays": 36500, "env": {"GIT_BASE": "@HOME@/git"}}
EOF
cat > "$FIXTURE/settings.termux.json" <<'EOF'
{"refreshInterval": 5000}
EOF

DST1="$SANDBOX/settings-1.json"
if run_merge "$FIXTURE" "settings.termux.json" "$DST1" >/dev/null 2>&1; then
  ok "merge script exits 0 on a well-formed fixture"
else
  nope "merge script failed on a well-formed fixture"
fi

[ -f "$DST1" ] && ok "deployed file written" || { nope "no deployed file"; }

if [ -f "$DST1" ] && [ "$(jq -r '.cleanupPeriodDays' "$DST1")" = "36500" ]; then
  ok "base-only key (cleanupPeriodDays) survives the merge"
else
  nope "base-only key did NOT survive the merge — this is the 2026-08-20 bug"
fi

if [ -f "$DST1" ] && [ "$(jq -r '.refreshInterval' "$DST1")" = "5000" ]; then
  ok "overlay key (refreshInterval) present in the merge"
else
  nope "overlay key missing from the merge"
fi

if [ -f "$DST1" ] && [ "$(jq -r '.env.GIT_BASE' "$DST1")" = "$SANDBOX/home/git" ]; then
  ok "@HOME@ placeholder substituted"
else
  nope "@HOME@ placeholder not substituted"
fi

# ── Phase 2 · missing SoT must fail LOUD, not silently keep stale output ────
echo "▶ Phase 2 · missing SoT fails loud"
DST2="$SANDBOX/settings-2.json"
echo '{"stale": true}' > "$DST2"
if run_merge "$SANDBOX/does-not-exist" "settings.termux.json" "$DST2" >/dev/null 2>&1; then
  nope "merge script exited 0 with a missing SoT — staleness would be silent"
else
  ok "merge script exits non-zero when the SoT is missing"
fi
[ "$(jq -r '.stale' "$DST2" 2>/dev/null)" = "true" ] \
  && ok "missing-SoT failure leaves the previous deployed file UNCHANGED (no partial overwrite)" \
  || nope "missing-SoT failure clobbered the previously-deployed file"

# ── Phase 3 · claude-assets-deploy.sh carries a SoT-only agent file through ─
echo "▶ Phase 3 · asset deploy"
SOT3="$SANDBOX/fixture-sot"
mkdir -p "$SOT3/agents" "$SOT3/cloud-marketplace"
echo 'marker-content' > "$SOT3/agents/probe.md"
echo '{}' > "$SOT3/claude-plugins.json"
echo 'x' > "$SOT3/rgignore"
DEST3="$SANDBOX/dot-claude"
REPO_SOT="$SOT3" DEST_CLAUDE="$DEST3" DEST_RGIGNORE="$SANDBOX/rgignore-out" \
  bash "$DEPLOY_SCRIPT" >/dev/null 2>&1
[ -f "$DEST3/agents/probe.md" ] && ok "agents/ copied from the checkout" || nope "agents/ not deployed"
[ -f "$DEST3/claude-plugins.json" ] && ok "claude-plugins.json copied" || nope "claude-plugins.json not deployed"
[ -f "$SANDBOX/rgignore-out" ] && ok "rgignore copied" || nope "rgignore not deployed"

# ── Phase 4 · THE REAL check — real SoT + real overlay, real script ────────
# This is the assertion that actually catches a repeat of 2026-08-18..20: if
# someone adds a base-only key to the real settings.base.json and the merge
# script (or its call site in claude.nix) stops carrying it through, this
# fails without needing a phone.
echo "▶ Phase 4 · real da_my-ai SoT merged with the real script"
if [ -d "$REAL_SOT" ]; then
  DST4="$SANDBOX/settings-real.json"
  if run_merge "$REAL_SOT" "settings.termux.json" "$DST4" >/dev/null 2>&1; then
    ok "real SoT + real termux overlay merge cleanly"
    REAL_CLEANUP=$(jq -r '.cleanupPeriodDays // "MISSING"' "$DST4")
    if [ "$REAL_CLEANUP" != "MISSING" ] && [ "$REAL_CLEANUP" != "null" ]; then
      ok "real deployed settings carry cleanupPeriodDays ($REAL_CLEANUP) from the SoT"
    else
      nope "real da_my-ai settings.base.json has no cleanupPeriodDays — retention regression"
    fi
  else
    nope "real SoT + real overlay FAILED to merge"
  fi
else
  nope "da_my-ai checkout not found at $REAL_SOT — cannot run the real-SoT check"
fi

# ── Phase 5 · the pinned-input trap cannot come back ────────────────────────
echo "▶ Phase 5 · no pinned my-ai flake input"
if grep -q 'my-ai = {' "$FLAKE_NIX" 2>/dev/null || grep -qE '^\s*my-ai\.url' "$FLAKE_NIX" 2>/dev/null; then
  nope "flake.nix declares a my-ai input again — the staleness trap is back"
else
  ok "flake.nix has no my-ai flake input"
fi
# Comments are allowed to keep discussing the old pin for history's sake —
# what must not come back is a live `url = "...?dir=da_my-ai"` input line.
grep -v '^\s*#' "$FLAKE_NIX" | grep -q '?dir=da_my-ai' \
  && nope "flake.nix still has a LIVE github:...?dir=da_my-ai input URL" \
  || ok "flake.nix does not pin da_my-ai as a remote flake input"
grep -q 'claudeSrc' "$CLAUDE_NIX" 2>/dev/null \
  && nope "claude.nix still takes a claudeSrc module arg (flake-input read reintroduced)" \
  || ok "claude.nix takes no claudeSrc arg (reads the checkout directly)"

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
