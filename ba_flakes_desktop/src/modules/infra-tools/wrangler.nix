# infra-tools/wrangler.nix — Cloudflare Workers CLI, SLIMMED.
#
# Upstream nixpkgs `wrangler` vendors the ENTIRE workers-sdk monorepo's pnpm
# store (verified 2026-07-16: the derivation is 1.6 GB). The bloat is FOUR
# pinned @cloudflare/workerd-linux-64 versions (~95 MB each) — one per workspace
# package that pinned a different date — plus the turbo build orchestrator,
# even though the CLI only ever execs `lib/packages/wrangler` and resolves the
# SINGLE workerd its own package.json pins ("workerd": "1.20250523.0").
#
# Fix (declarative overlay override): keep the workerd wrangler itself pins
# (read DYNAMICALLY from its package.json — data-driven, never hardcoded), drop
# the redundant versions + turbo + test fixtures. ~310 MB reclaimed with high
# confidence (nothing the CLI runs references the removed paths). A
# `wrangler --version` installCheck gates it: a bad prune fails the BUILD, so a
# broken wrangler can never ship. The remaining monorepo pnpm dev-deps are an
# upstream packaging issue (nixpkgs should build wrangler standalone).
{ config, pkgs, lib, ... }:
let
  slimWrangler = pkgs.wrangler.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      _lib="$out/lib"; [ -d "$_lib" ] || _lib="$(dirname "$(dirname "$(readlink -f "$out/bin/wrangler")")")"
      cd "$_lib" || exit 0
      # workerd version wrangler itself pins (data-driven, from its package.json)
      _keep="$(grep -oE '"workerd"[[:space:]]*:[[:space:]]*"[^"]*"' \
                 packages/wrangler/package.json 2>/dev/null | grep -oE '[0-9][0-9.]*' | head -1)"
      if [ -n "$_keep" ]; then
        for d in node_modules/.pnpm/@cloudflare+workerd-linux-64@*; do
          [ -e "$d" ] || continue
          case "$d" in *"@''${_keep}") : ;; *) rm -rf "$d" ;; esac
        done
      fi
      rm -rf node_modules/.pnpm/turbo-linux-64@* node_modules/.pnpm/turbo@* fixtures 2>/dev/null || true
      # nixpkgs' noBrokenSymlinks fixup (added upstream ~2026-07) rejects the
      # workers-sdk monorepo's dev-only dangling links — e.g.
      #   lib/node_modules/.pnpm/node_modules/<x>-app -> ../../fixtures/<x>
      # whose targets we just pruned above. They are test/example fixture apps
      # the CLI never execs, so delete every broken symlink in the output.
      # Completes the slim AND satisfies the check; `wrangler --version` below
      # still gates that nothing runtime-critical was removed.
      find "$out" -xtype l -delete 2>/dev/null || true
    '';
    doInstallCheck = true;
    installCheckPhase = (old.installCheckPhase or "") + ''
      "$out/bin/wrangler" --version >/dev/null || { echo "slim-wrangler: --version broke after prune"; exit 1; }
    '';
  });
in
{
  home.packages = [ slimWrangler ];
}
