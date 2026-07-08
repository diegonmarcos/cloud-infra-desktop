# containers-cloud/waydroid-container.nix — desktop launcher for the Waydroid-in-Docker
# container (replaces Redroid — archived to z_archive/da_redroid after Brave/Chromium
# was confirmed to crash unfixably under redroid's stock AOSP image, which needs a real
# /dev/ashmem this mainline kernel doesn't have. Waydroid's vendor image is memfd-native
# since 1.2.1+ and needs no ashmem at all).
#
# Display transport (redesigned 2026-07-08 for a FULL GPU pipeline): Sunshine inside the
# container (VAAPI hardware H.264 encode of the headless sway output on the passed-through
# Intel render node) + Moonlight on the host (hardware decode) — end-to-end GPU:
# Android hwcomposer EGL render → sway GLES2 composite → VAAPI encode → Moonlight decode.
# TigerVNC/wayvnc remains the debug/fallback transport (`waydroid-container up vnc`).
# The container image itself is BUILT IN GHA and pulled from GHCR (ship-waydroid-container
# workflow) — `up` on a fresh machine pulls, never builds.
#
# The container, boot sequence, pairing and teardown are all owned by the data-driven
# engine at ~/git/unix/da_waydroid-container/build.sh (nothing hardcoded here). This HM
# module provides the user-facing wiring: the ONE-CLICK launcher binary
# (`~/.local/bin/waydroid-container` — open it and the whole stack comes up: container
# pull/start, Android boot, Sunshine pairing, Moonlight window), a KDE `.desktop` entry,
# the client packages on PATH, and the KDE taskbar (icontasks) pin. `up` is GUI-bound:
# closing the Moonlight window tears down every stack the container started. NO systemd
# user service, NO autostart, NO watchdog-respawn — that was the original
# desktop-session Waydroid's ghost-process class of bug.
{ config, pkgs, lib, ... }:
let
  engine = "$HOME/git/unix/da_waydroid-container/build.sh";
  desktopId = "waydroid-container";
in {
  # Clients declared here (not resolved at click-time by the engine's `nix build`
  # fallback) so the first launch from the KDE menu is instant — and immune to the
  # nix-daemon being down/GC'd paths (a live failure mode: the engine's runtime
  # `nix build` fallback died with 'could not resolve vncviewer' when the daemon
  # socket was frozen). moonlight-qt = primary; tigervnc = fallback transport.
  home.packages = [ pkgs.moonlight-qt pkgs.tigervnc ];

  # `waydroid-container` — THE one-click binary: opens the full stack (GHCR pull if
  # needed → container up → Android boot → Sunshine pairing → Moonlight GUI), and
  # closing the GUI window stops everything. `waydroid-container down` stops it
  # explicitly; `waydroid-container up vnc` uses the fallback transport. Thin wrapper
  # over the engine so there is ONE source of truth (da_waydroid-container/build.sh).
  home.file.".local/bin/waydroid-container" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      ENGINE="${engine}"
      [ -x "$ENGINE" ] || { echo "waydroid-container engine not found at $ENGINE (clone ~/git/unix)"; exit 1; }
      case "''${1:-up}" in
        up|"")  shift 2>/dev/null || true; exec "$ENGINE" up "$@" ;;
        down)   exec "$ENGINE" down ;;
        *)      exec "$ENGINE" "$@" ;;
      esac
    '';
  };

  # KDE application menu entry. Exec uses an absolute path — desktop-entry Exec does NOT
  # expand `%h`; ~/.local/bin is also not guaranteed on the launcher's PATH.
  xdg.desktopEntries.${desktopId} = {
    name = "Waydroid";
    comment = "Android (Waydroid-in-Docker) — GPU-streamed via Sunshine/Moonlight";
    exec = "${config.home.homeDirectory}/.local/bin/waydroid-container up";
    terminal = false;
    icon = "smartphone";
    categories = [ "System" ];
    # KDE's taskbar matches a running window to a pinned launcher by comparing the
    # window's WM_CLASS to the desktop file's StartupWMClass. The window that opens is
    # Moonlight's ("Moonlight"). Verify via `xprop WM_CLASS` if a Moonlight version
    # bump ever changes it.
    settings.StartupWMClass = "Moonlight";
  };

  # Pin the launcher to the KDE Plasma taskbar (icontasks) — plasma-manager's
  # configFile cannot write the hierarchical [Containments][N][Applets][M] groups
  # (it escapes the brackets into broken \x5d\x5b headers), so this uses
  # kwriteconfig6 in home.activation, the sanctioned pattern for hierarchical KDE
  # INI groups. Idempotent: skips if already pinned. The pin renders on the next
  # plasmashell restart/login.
  home.activation.pinWaydroidContainerTaskbar = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    rc="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
    entry="applications:${desktopId}.desktop"
    if [ -f "$rc" ] && ! ${pkgs.gnugrep}/bin/grep -q "$entry" "$rc"; then
      ids="$(${pkgs.gawk}/bin/awk '
        /^\[Containments\]\[[0-9]+\]\[Applets\]\[[0-9]+\]$/ {
          g=$0; sub(/^\[Containments\]\[/,"",g); sub(/\]\[Applets\]\[/," ",g); sub(/\]$/,"",g); grp=g
        }
        /^plugin=org\.kde\.plasma\.icontasks$/ { print grp; exit }
      ' "$rc")"
      if [ -n "$ids" ]; then
        cid="''${ids%% *}"; aid="''${ids##* }"
        cur="$(${pkgs.kdePackages.kconfig}/bin/kreadconfig6 --file "$rc" \
          --group Containments --group "$cid" --group Applets --group "$aid" \
          --group Config --group General --key launchers 2>/dev/null || true)"
        case ",$cur," in *",$entry,"*) : ;; *)
          run ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 --file "$rc" \
            --group Containments --group "$cid" --group Applets --group "$aid" \
            --group Config --group General --key launchers "''${cur:+$cur,}$entry"
        ;; esac
      fi
    fi
  '';
}
