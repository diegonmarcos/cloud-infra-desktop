# claude-marketplace-register — register cloud-marketplace + materialize the
# plugin cache installPaths Claude Code's /plugin loader validates.
# Env contract: JQ_BIN. Explicit claude path — activation PATH lacks
# ~/.nix-profile/bin.
MARKETPLACE_DIR="$HOME/.claude/cloud-marketplace"
CLAUDE="$HOME/.nix-profile/bin/claude"
if [ -x "$CLAUDE" ] && [ -d "$MARKETPLACE_DIR" ]; then
  "$CLAUDE" plugin marketplace add "$MARKETPLACE_DIR" >/dev/null 2>&1 || true
  echo "[claude-marketplace] cloud-marketplace registered (enabledPlugins declared in settings.json)"
  # Durable installPath materialization: symlink each plugin's cache
  # entry (plugins/cache/<mkt>/<plugin>/<version>) at the store-backed
  # marketplace dir. Data-driven from marketplace.json + plugin.json.
  CACHE_DIR="$HOME/.claude/plugins/cache/cloud-marketplace"
  MKT_JSON="$MARKETPLACE_DIR/.claude-plugin/marketplace.json"
  if [ -f "$MKT_JSON" ]; then
    for P in $("$JQ_BIN" -r '.plugins[].name' "$MKT_JSON" 2>/dev/null); do
      VER=$("$JQ_BIN" -r '.version // "1.0.0"' "$MARKETPLACE_DIR/$P/.claude-plugin/plugin.json" 2>/dev/null || echo "1.0.0")
      DEST="$CACHE_DIR/$P/$VER"
      mkdir -p "$CACHE_DIR/$P"
      [ -e "$DEST" ] && [ ! -L "$DEST" ] && rm -rf "$DEST"
      ln -sfn "$MARKETPLACE_DIR/$P" "$DEST"
      echo "[claude-marketplace] materialized $P@$VER -> cache installPath"
    done
  fi
else
  echo "[claude-marketplace] WARNING: skipping — missing: $([ -x "$CLAUDE" ] || echo "$CLAUDE ")$([ -d "$MARKETPLACE_DIR" ] || echo "$MARKETPLACE_DIR")"
fi
