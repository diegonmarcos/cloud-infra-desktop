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

  # ── Project launcher icon (replaces the fallback "W" tile) ──────────
  # A project-connected SVG (cloud + terminal prompt in the #7b7fff accent),
  # installed into the hicolor theme so both the menu launcher and the task
  # manager resolve it by name.
  home.file.".local/share/icons/hicolor/scalable/apps/cloud-terminal.svg".source = ./cloud-terminal.svg;

  # ── Persistent, declarative desktop entry (the menu-bar shortcut) ───
  # Exec points at the on-PATH launcher (build.sh run). StartupWMClass matches
  # the Tauri app id so KDE groups the running window under THIS icon (not the
  # generic fallback). Opens the Home profile (multi-tray) by default.
  xdg.desktopEntries."cloud-terminal" = {
    name = "Cloud Terminal";
    genericName = "Terminal + Cloud Control";
    comment = "Registry-driven multi-profile terminal, system + cloud dashboards";
    exec = "${config.home.homeDirectory}/.local/bin/cloud-terminal";
    icon = "cloud-terminal";
    terminal = false;
    type = "Application";
    startupNotify = true;
    categories = [ "System" "TerminalEmulator" "Utility" ];
    settings.StartupWMClass = "com.diegonmarcos.cloud-terminal";
  };

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
