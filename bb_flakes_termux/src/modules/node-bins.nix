# Global npm binaries — installed once, updated on `build.sh switch`
# Each activation checks current version vs latest and updates if needed.
{ config, lib, pkgs, nodejs, ... }:

{
  # tsx (TypeScript runner)
  # tsx + wrangler — body in scripts/node-bins-install.sh (was two inline
  # blocks; `command -v tsx` on the minimal activation PATH reinstalled tsx
  # on every switch)
  home.activation.globalTsx = lib.hm.dag.entryAfter ["linkGeneration"] ''
    NODEJS_DIR="${nodejs}/bin" ${pkgs.bash}/bin/bash ${./scripts/node-bins-install.sh} || true
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
