# claude-assets-deploy — copy agents/, cloud-marketplace/, claude-plugins.json,
# rgignore FROM THE WORKING CHECKOUT AT ACTIVATION TIME. Same staleness fix as
# claude-settings-merge.sh — see that script's header for the full rationale.
#
# TRADEOFF, stated: home.file (the old mechanism) tracked these and removed
# them when undeclared; a plain copy does not. Deleting an agent from the SoT
# now leaves the stale file in ~/.claude until the next deploy — hence
# agents/ and cloud-marketplace/ are wiped-then-copied rather than merged
# (rm -rf + cp -a), which is close enough for a directory that is the whole
# of the semantics. A single file removed from the SoT (claude-plugins.json,
# rgignore) is not swept and must be deleted by hand.
#
# Env contract: REPO_SOT (dir holding agents/ cloud-marketplace/ etc.)
# DEST_CLAUDE (~/.claude) DEST_RGIGNORE (~/.rgignore) MCP_VARIANT (which
# mcp.<variant>.json.tpl to deploy as mcp.json.tpl) CP_BIN RM_BIN MKDIR_BIN
# CHMOD_BIN (tool paths, default to PATH so this script is directly
# runnable/testable standalone).
set -u
CP_BIN="${CP_BIN:-cp}"
RM_BIN="${RM_BIN:-rm}"
MKDIR_BIN="${MKDIR_BIN:-mkdir}"
CHMOD_BIN="${CHMOD_BIN:-chmod}"

"$MKDIR_BIN" -p "$DEST_CLAUDE"
if [ ! -d "$REPO_SOT" ]; then
  echo "[claude-assets] FATAL: SoT missing at $REPO_SOT — assets NOT deployed" >&2
  exit 1
fi

for d in agents cloud-marketplace; do
  if [ -d "$REPO_SOT/$d" ]; then
    "$RM_BIN" -rf "$DEST_CLAUDE/$d"
    "$CP_BIN" -a "$REPO_SOT/$d" "$DEST_CLAUDE/$d"
  else
    echo "[claude-assets] WARN: $REPO_SOT/$d absent — left as-is" >&2
  fi
done

[ -f "$REPO_SOT/claude-plugins.json" ] && "$CP_BIN" -f "$REPO_SOT/claude-plugins.json" "$DEST_CLAUDE/claude-plugins.json"
[ -f "$REPO_SOT/rgignore" ] && "$CP_BIN" -f "$REPO_SOT/rgignore" "$DEST_RGIGNORE"

# The MCP template is platform-specific (termux bans the stdio servers desktop
# declares) but it is still claude SETTINGS, so it lives in the one SoT dir
# under a platform suffix — exactly like settings.termux.json. It was a
# home.file pointing into this flake, i.e. a second SoT, until 2026-08-27.
MCP_VARIANT="${MCP_VARIANT:-termux}"
MCP_TPL="$REPO_SOT/mcp.$MCP_VARIANT.json.tpl"
if [ -f "$MCP_TPL" ]; then
  "$CP_BIN" -f --no-preserve=mode "$MCP_TPL" "$DEST_CLAUDE/mcp.json.tpl"
else
  echo "[claude-assets] FATAL: $MCP_TPL missing — ~/.mcp.json would go stale" >&2
  exit 1
fi
"$CHMOD_BIN" -R u+w "$DEST_CLAUDE/agents" "$DEST_CLAUDE/cloud-marketplace" 2>/dev/null || true
echo "[claude-assets] deployed from $REPO_SOT (single SoT)"
