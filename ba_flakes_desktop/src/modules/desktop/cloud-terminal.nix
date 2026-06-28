# cloud-terminal.nix — pull + install the Cloud Terminal (da_cloud-terminal) from
# its rolling GitHub Release instead of building it locally.
#
# The CI workflow (ship-cloud-terminal.yml) publishes a payload tarball to the
# `latest` GH Release (+ GHCR). On home-manager activation we run
# `da_cloud-terminal/build.sh pull`, which is VERSION-GUARDED: it compares the
# published version to the installed marker and only downloads + reinstalls on
# change, emitting the per-profile launchers into ~/.local/bin (electron/node
# resolved locally). It NEVER blocks activation (bounded by `timeout`, `|| true`).
#
# Runtime deps the launcher + pull need: electron (the GUI runtime, resolved from
# the nix store by build.sh), nodejs (the PTY helper), zstd + curl + jq (pull).
{ config, lib, pkgs, ... }:
let
  repoDir = "${config.home.homeDirectory}/git/unix/da_cloud-terminal";
in
{
  home.packages = with pkgs; [ electron nodejs zstd curl jq fish ];

  # Version-guarded pull on every activation. Cheap no-op when already current.
  home.activation.cloudTerminalPull =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ -x "${repoDir}/build.sh" ]; then
        export PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.curl pkgs.zstd pkgs.jq pkgs.gnutar pkgs.nodejs pkgs.electron pkgs.bash ]}:$PATH"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/timeout 120 \
          ${pkgs.bash}/bin/bash "${repoDir}/build.sh" pull || \
          echo "cloud-terminal: pull skipped/failed (non-fatal)"
      else
        echo "cloud-terminal: ${repoDir}/build.sh absent — skipping pull"
      fi
    '';
}
