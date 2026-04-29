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

  # Claude Code installation REMOVED from this module.
  #
  # Was: `npm install -g @anthropic-ai/claude-code` at every activation.
  # OOM-killed by Android ~50% of the time, with `|| true` masking the
  # failure → user ended up with no claude binary and no error.
  #
  # Now: claude-code is a real nix derivation in pkgs/claude-code/default.nix
  # added to environment.packages in flake.nix. Permanent store path,
  # deterministic, no runtime npm.
}
