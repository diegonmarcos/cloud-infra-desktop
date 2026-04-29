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

  # Claude Code (@anthropic-ai/claude-code)
  home.activation.globalClaudeCode = lib.hm.dag.entryAfter ["linkGeneration"] ''
    PATH="${nodejs}/bin:$PATH"
    CURRENT=$(${nodejs}/bin/node -e "try{console.log(require('@anthropic-ai/claude-code/package.json').version)}catch{}" 2>/dev/null || true)
    LATEST=$(${nodejs}/bin/npm view @anthropic-ai/claude-code version 2>/dev/null || true)

    # Clean stale npm temp dirs from prior failed upgrades (ENOTEMPTY bug)
    for d in /data/data/com.termux.nix/files/usr/lib/node_modules/@anthropic-ai/.claude-code-*; do
      [ -d "$d" ] && rm -rf "$d"
    done

    # Helper: never block activation, but print the npm exit code loudly so
    # the post-switch verifier in build.sh sees a missing binary AND the user
    # gets a visible warning. The previous `|| true` pattern silently swallowed
    # OOM kills (SIGTERM) on Android, leaving claude-code uninstalled.
    _install() {
      $DRY_RUN_CMD ${nodejs}/bin/npm install -g "$@" --no-audit --no-fund
      _rc=$?
      if [ "$_rc" -ne 0 ]; then
        printf "[node-bins] WARN: npm install %s FAILED (exit %d) — likely SIGTERM/OOM. build.sh verify will flag the missing binary.\n" "$*" "$_rc" >&2
      fi
      return 0
    }

    if [ -z "$CURRENT" ]; then
      printf "[node-bins] Installing claude-code@%s\n" "$LATEST"
      _install "@anthropic-ai/claude-code"
    elif [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
      printf "[node-bins] Updating claude-code: %s → %s\n" "$CURRENT" "$LATEST"
      _install "@anthropic-ai/claude-code@latest" --force
    else
      printf "[node-bins] claude-code@%s is up to date\n" "$CURRENT"
    fi
  '';
}
