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

  # Wrangler (Cloudflare Workers CLI — needs 3.60+ for [observability])
  home.activation.globalWrangler = lib.hm.dag.entryAfter ["linkGeneration"] ''
    PATH="${nodejs}/bin:$PATH"
    CURRENT=$(${nodejs}/bin/node -e "try{console.log(require('wrangler/package.json').version)}catch{}" 2>/dev/null || true)
    LATEST=$(${nodejs}/bin/npm view wrangler version 2>/dev/null || true)

    # Remove stale wrangler2 symlink from old nix package (conflicts with npm global)
    for stale in wrangler2; do
      [ -L "/data/data/com.termux.nix/files/usr/bin/$stale" ] && rm -f "/data/data/com.termux.nix/files/usr/bin/$stale"
    done

    if [ -z "$CURRENT" ]; then
      printf "[node-bins] Installing wrangler@%s\n" "$LATEST"
      $DRY_RUN_CMD ${nodejs}/bin/npm install -g wrangler --no-audit --no-fund --force || true
    elif [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
      printf "[node-bins] Updating wrangler: %s → %s\n" "$CURRENT" "$LATEST"
      $DRY_RUN_CMD ${nodejs}/bin/npm install -g wrangler@latest --no-audit --no-fund || true
    else
      printf "[node-bins] wrangler@%s is up to date\n" "$CURRENT"
    fi
  '';

  # Claude Code — direct Bun binary from Anthropic GCS (no npm)
  home.activation.globalClaudeCode = lib.hm.dag.entryAfter ["linkGeneration"] ''
    CLAUDE_BIN="$HOME/.local/bin/claude"
    CLAUDE_GCS="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
    ARCH="linux-arm64"

    mkdir -p "$HOME/.local/bin"

    CURRENT=""
    if [ -x "$CLAUDE_BIN" ]; then
      CURRENT=$("$CLAUDE_BIN" --version 2>/dev/null | head -1 | sed 's/ .*//' || true)
    fi
    LATEST=$(${nodejs}/bin/npm view @anthropic-ai/claude-code version 2>/dev/null || true)

    if [ -z "$CURRENT" ]; then
      printf "[claude-code] Installing %s (%s)\n" "$LATEST" "$ARCH"
      $DRY_RUN_CMD curl -fsSL "$CLAUDE_GCS/$LATEST/$ARCH/claude" -o "$CLAUDE_BIN"
      $DRY_RUN_CMD chmod 755 "$CLAUDE_BIN"
    elif [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
      printf "[claude-code] Updating: %s → %s\n" "$CURRENT" "$LATEST"
      $DRY_RUN_CMD curl -fsSL "$CLAUDE_GCS/$LATEST/$ARCH/claude" -o "$CLAUDE_BIN"
      $DRY_RUN_CMD chmod 755 "$CLAUDE_BIN"
    else
      printf "[claude-code] %s is up to date\n" "$CURRENT"
    fi
  '';
}
