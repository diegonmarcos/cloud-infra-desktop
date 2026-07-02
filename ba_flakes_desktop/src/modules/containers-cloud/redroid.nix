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
  # `redroid` — bring the container up (idempotent), provision (idempotent), then mirror.
  # `redroid down` stops it. Thin wrapper over the engine so there is ONE source of truth.
  home.file.".local/bin/redroid" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      ENGINE="${engine}"
      [ -x "$ENGINE" ] || { echo "redroid engine not found at $ENGINE (clone ~/git/unix)"; exit 1; }
      case "''${1:-up}" in
        up|"")     "$ENGINE" up && "$ENGINE" provision && exec "$ENGINE" scrcpy ;;
        mirror)    exec "$ENGINE" scrcpy ;;
        down)      exec "$ENGINE" down ;;
        provision) exec "$ENGINE" provision ;;
        *)         exec "$ENGINE" "$@" ;;
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
  };
}
