# cloud-terminal.nix — install the Cloud Terminal (da_cloud-terminal, Tauri/Rust)
# `cloud-terminal` launcher on PATH.
#
# The `~/.local/bin/cloud-terminal` launcher is a DECLARATIVE home.file (a
# home-manager-managed store symlink) — present + reproducible after every
# `home-manager switch`, tracked in generations, no imperative activation step.
# It's a tiny launcher (not a direct binary symlink): it execs `build.sh run`,
# which resolves the Tauri binary + its webkit/glibc runtime libs (fetch the CI
# build / nix-develop) and picks the newest binary. A raw symlink to the binary
# would launch without LD_LIBRARY_PATH and fail to load webkit — the indirection
# is required. No electron, no node, no bundled Chromium.
{ config, lib, pkgs, ... }:
let
  repoDir = "${config.home.homeDirectory}/git/cloud-unix/da_cloud-terminal";
in
{
  # No electron/nodejs — the Tauri app is self-contained (native webview + PTY).
  home.packages = with pkgs; [ zstd curl jq ];

  # NOTE: no shellAlias — the `cloud-terminal` launcher lives on PATH
  # (~/.local/bin, the declarative home.file below). An alias would shadow it.

  # ── Declarative launcher symlink on PATH (~/.local/bin/cloud-terminal) ──
  # home-manager owns this file (store symlink) — appears/updates on every
  # switch, no imperative `build.sh install`. Execs `build.sh run` so binary
  # + runtime-lib resolution and newest-build selection stay in the engine.
  home.file.".local/bin/cloud-terminal" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Cloud Terminal (Tauri) launcher — managed declaratively by home-manager.
      exec ${pkgs.bash}/bin/bash "${repoDir}/build.sh" run "$@"
    '';
  };

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

}
