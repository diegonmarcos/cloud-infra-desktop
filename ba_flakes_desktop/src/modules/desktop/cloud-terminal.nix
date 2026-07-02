# cloud-terminal.nix — install the Cloud Terminal (da_cloud-terminal, Tauri/Rust)
# `cloud-terminal` launcher on PATH.
#
# On home-manager activation we run `da_cloud-terminal/build.sh install`, which
# writes a single `~/.local/bin/cloud-terminal` launcher (opens the Tauri app,
# all profile trays via CT_MULTI, through `build.sh run`) and removes the stale
# per-profile ELECTRON launchers the Tauri app replaced. Cheap + idempotent;
# never blocks activation (`|| true`). The Tauri binary + its runtime libs are
# resolved by `build.sh run` (fetch the CI build / nix-develop for webkit+glibc)
# — no electron, no node, no bundled Chromium.
{ config, lib, pkgs, ... }:
let
  repoDir = "${config.home.homeDirectory}/git/unix/da_cloud-terminal";
in
{
  # No electron/nodejs — the Tauri app is self-contained (native webview + PTY).
  home.packages = with pkgs; [ zstd curl jq ];

  # NOTE: no shellAlias — the `cloud-terminal` launcher lives on PATH
  # (~/.local/bin, emitted by `build.sh install`). An alias here would shadow it.

  home.activation.cloudTerminalInstall =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ -x "${repoDir}/build.sh" ]; then
        $DRY_RUN_CMD ${pkgs.bash}/bin/bash "${repoDir}/build.sh" install || \
          echo "cloud-terminal: install skipped/failed (non-fatal)"
      else
        echo "cloud-terminal: ${repoDir}/build.sh absent — skipping install"
      fi
    '';
}
