# containers-cloud/waydroid-container.nix — desktop launcher for the Waydroid-in-Docker
# container (replaces Redroid — archived to z_archive/da_redroid after Brave/Chromium
# was confirmed to crash unfixably under redroid's stock AOSP image, which needs a real
# /dev/ashmem this mainline kernel doesn't have. Waydroid's vendor image is memfd-native
# since 1.2.1+ and needs no ashmem at all — verified working end-to-end 2026-07-08).
#
# Display transport is sway (headless wlroots) + wayvnc, not weston+RDP: Debian
# bookworm's weston 10.0.1 rdp-backend.so has a confirmed dead-connection bug (accepts
# the TCP handshake, never services the RDP protocol negotiation) and has no
# vnc-backend.so either — sway+wayvnc is the standard, actively-maintained combo for
# headless-Wayland VNC (swapped 2026-07-04).
#
# The container, boot sequence and teardown are all owned by the data-driven engine at
# ~/git/unix/da_waydroid-container/build.sh (nothing hardcoded here). This HM module
# only provides the user-facing launcher: a `.local/bin/waydroid-container` wrapper +
# a KDE `.desktop` entry, plus tigervnc on PATH so the menu click doesn't stall on the
# engine's runtime `nix build` fallback. `up` is the ONLY launch path the engine
# exposes — it is GUI-bound (vncviewer attaches in the foreground; closing the window
# tears down every stack the container started: waydroid session/container, wayvnc,
# sway, seatd, pulseaudio, both D-Bus daemons). NO systemd user service, NO autostart,
# NO watchdog-respawn — that was the original desktop-session Waydroid's ghost-process
# class of bug.
{ config, pkgs, lib, ... }:
let
  engine = "$HOME/git/unix/da_waydroid-container/build.sh";
in {
  # tigervnc declared here (not just resolved at click-time by the engine's `nix build`
  # fallback) so the first launch from the KDE menu is instant, not a multi-second
  # store fetch. The engine keeps its own `tool()` fallback for non-HM machines.
  home.packages = [ pkgs.tigervnc ];

  # `waydroid-container` — bring the container up and attach the VNC GUI (GUI-bound:
  # closing the vncviewer window stops every stack). `waydroid-container down` stops it
  # explicitly. Thin wrapper over the engine so there is ONE source of truth
  # (da_waydroid-container/build.sh) — never `up && vncviewer`, which would double-launch
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
    comment = "Android (Waydroid-in-Docker) — full Chromium/Brave support via VNC";
    exec = "${config.home.homeDirectory}/.local/bin/waydroid-container up";
    terminal = true;
    icon = "smartphone";
    categories = [ "System" ];
    # KDE's taskbar matches a running window to a PINNED launcher by comparing the
    # window's WM_CLASS to the desktop file's class (defaults to the desktop file id
    # if unset). The window that actually opens is TigerVNC's own vncviewer window
    # (WM_CLASS defaults to the binary name, "vncviewer", per X11 convention — no
    # custom class set by the app) — without this the pin never associates with the
    # running app. Verify live via `xprop WM_CLASS` on the open window if this ever
    # drifts from a TigerVNC version bump.
    settings.StartupWMClass = "vncviewer";
  };
}
