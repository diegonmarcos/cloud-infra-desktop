# Global npm binaries — installed once, updated on `build.sh switch`
# Each activation checks current version vs latest and updates if needed.
{ config, lib, pkgs, nodejs, ... }:

{
  # tsx (TypeScript runner)
  home.activation.globalTsx = lib.hm.dag.entryAfter ["linkGeneration"] ''
    PATH="${nodejs}/bin:$PATH"
    if ! command -v tsx >/dev/null 2>&1; then
      $DRY_RUN_CMD ${nodejs}/bin/npm install -g tsx --no-audit --no-fund || true
    fi
  '';

  # Claude Code (@anthropic-ai/claude-code)
  home.activation.globalClaudeCode = lib.hm.dag.entryAfter ["linkGeneration"] ''
    PATH="${nodejs}/bin:$PATH"
    CURRENT=$(${nodejs}/bin/node -e "try{console.log(require('@anthropic-ai/claude-code/package.json').version)}catch{}" 2>/dev/null || true)
    LATEST=$(${nodejs}/bin/npm view @anthropic-ai/claude-code version 2>/dev/null || true)

    if [ -z "$CURRENT" ]; then
      printf "[node-bins] Installing claude-code@%s\n" "$LATEST"
      $DRY_RUN_CMD ${nodejs}/bin/npm install -g @anthropic-ai/claude-code --no-audit --no-fund || true
    elif [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
      printf "[node-bins] Updating claude-code: %s → %s\n" "$CURRENT" "$LATEST"
      $DRY_RUN_CMD ${nodejs}/bin/npm install -g @anthropic-ai/claude-code@latest --no-audit --no-fund || true
    else
      printf "[node-bins] claude-code@%s is up to date\n" "$CURRENT"
    fi
  '';
}
