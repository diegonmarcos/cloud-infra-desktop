# containers-cloud/redroid.nix — desktop launcher for the Redroid Android container.
#
# Redroid replaces Waydroid. The container, app set, launcher layout and theme are all
# owned by the data-driven engine at ~/git/unix/da_redroid/build.sh (nothing hardcoded
# here). This HM module only provides the user-facing launcher: a `.local/bin/redroid`
# wrapper + a KDE `.desktop` entry that brings the container up ON DEMAND and mirrors it
# with scrcpy. NO systemd user service, NO autostart, NO watchdog-respawn — that was the
# Waydroid ghost-process class of bug. Kernel binder + docker come from the NixOS host
# module configuration_redroid.nix.
{ config, pkgs, lib, ... }:
let
  engine = "$HOME/git/unix/da_redroid/build.sh";
in {
  # `redroid` — bring the container up and mirror it (GUI-bound: closing the scrcpy
  # window stops the container). `redroid down` stops it. Thin wrapper over the engine
  # so there is ONE source of truth (da_redroid/build.sh).
  home.file.".local/bin/redroid" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      ENGINE="${engine}"
      [ -x "$ENGINE" ] || { echo "redroid engine not found at $ENGINE (clone ~/git/unix)"; exit 1; }
      # The image is BAKED (apps + layout + theme already inside it), so runtime is just
      # pull+run+mirror — NO provision/install step. First `up` pulls the GHCR image.
      # `up` is GUI-bound in the engine: it boots the backend, attaches scrcpy in
      # the foreground, and stops the container when the GUI closes (no GUI => no
      # running redroid). So the wrapper just execs it — NEVER `up && scrcpy`, which
      # would double-launch scrcpy on a torn-down container.
      case "''${1:-up}" in
        up|""|mirror)  exec "$ENGINE" up ;;
        down)          exec "$ENGINE" down ;;
        *)             exec "$ENGINE" "$@" ;;
      esac
    '';
  };

  # KDE application menu entry. Exec uses an absolute path — desktop-entry Exec does NOT
  # expand `%h` (that's an invalid field code and fails desktop-file-validate); ~/.local/bin
  # is also not guaranteed on the launcher's PATH. Single main category (System) — listing
  # two main categories (System;Utility) trips the validator's duplicate-menu hint.
  xdg.desktopEntries.redroid = {
    name = "Redroid";
    comment = "Android (Redroid container) — mirror + control via scrcpy";
    exec = "${config.home.homeDirectory}/.local/bin/redroid up";
    terminal = true;
    icon = "smartphone";
    categories = [ "System" ];
    # KDE's taskbar matches a running window to a PINNED launcher by comparing the
    # window's WM_CLASS to the desktop file's class (defaults to the desktop file id,
    # "redroid", if unset). The window that actually opens is scrcpy's own window
    # (WM_CLASS=scrcpy — same value default-session.json's match_class uses for kwin
    # positioning), not "redroid". Without this, the mismatch means "Pin to Task Manager"
    # never associates with the running app — the launched window shows as a separate,
    # unpinned entry instead of lighting up the pin.
    settings.StartupWMClass = "scrcpy";
  };
}
