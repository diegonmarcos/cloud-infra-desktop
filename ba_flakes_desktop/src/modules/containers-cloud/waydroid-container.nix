# containers-cloud/waydroid-container.nix — desktop launcher for the Waydroid-in-Docker
# container (replaces Redroid — archived to z_archive/da_redroid after Brave/Chromium
# was confirmed to crash unfixably under redroid's stock AOSP image, which needs a real
# /dev/ashmem this mainline kernel doesn't have. Waydroid's vendor image is memfd-native
# since 1.2.1+ and needs no ashmem at all — verified working end-to-end this session).
#
# The container, boot sequence and teardown are all owned by the data-driven engine at
# ~/git/unix/da_waydroid-container/build.sh (nothing hardcoded here). This HM module
# only provides the user-facing launcher: a `.local/bin/waydroid-container` wrapper +
# a KDE `.desktop` entry. `up` is the ONLY launch path the engine exposes — it is
# GUI-bound (xfreerdp attaches in the foreground; closing the window tears down every
# stack the container started: waydroid session/container, weston, pulseaudio, both
# D-Bus daemons). NO systemd user service, NO autostart, NO watchdog-respawn — that
# was the original desktop-session Waydroid's ghost-process class of bug.
{ config, pkgs, lib, ... }:
let
  engine = "$HOME/git/unix/da_waydroid-container/build.sh";
in {
  # `waydroid-container` — bring the container up and attach the RDP GUI (GUI-bound:
  # closing the xfreerdp window stops every stack). `waydroid-container down` stops it
  # explicitly. Thin wrapper over the engine so there is ONE source of truth
  # (da_waydroid-container/build.sh) — never `up && xfreerdp`, which would double-launch
  # the GUI against a torn-down container.
  home.file.".local/bin/waydroid-container" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      ENGINE="${engine}"
      [ -x "$ENGINE" ] || { echo "waydroid-container engine not found at $ENGINE (clone ~/git/unix)"; exit 1; }
      case "''${1:-up}" in
        up|"")  exec "$ENGINE" up ;;
        down)   exec "$ENGINE" down ;;
        *)      exec "$ENGINE" "$@" ;;
      esac
    '';
  };

  # KDE application menu entry. Exec uses an absolute path — desktop-entry Exec does NOT
  # expand `%h`; ~/.local/bin is also not guaranteed on the launcher's PATH.
  xdg.desktopEntries.waydroid-container = {
    name = "Waydroid";
    comment = "Android (Waydroid-in-Docker) — full Chromium/Brave support via RDP";
    exec = "${config.home.homeDirectory}/.local/bin/waydroid-container up";
    terminal = true;
    icon = "smartphone";
    categories = [ "System" ];
    # KDE's taskbar matches a running window to a PINNED launcher by comparing the
    # window's WM_CLASS to the desktop file's class (defaults to the desktop file id
    # if unset). The window that actually opens is xfreerdp's own window
    # (WM_CLASS=xfreerdp), not "waydroid-container" — without this the pin never
    # associates with the running app.
    settings.StartupWMClass = "xfreerdp";
  };
}
