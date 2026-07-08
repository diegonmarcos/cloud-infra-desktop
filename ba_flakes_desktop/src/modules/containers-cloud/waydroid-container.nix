# containers-cloud/waydroid-container.nix — desktop launcher for the Waydroid-in-Docker
# container (replaces Redroid — archived to z_archive/da_redroid after Brave/Chromium
# was confirmed to crash unfixably under redroid's stock AOSP image, which needs a real
# /dev/ashmem this mainline kernel doesn't have. Waydroid's vendor image is memfd-native
# since 1.2.1+ and needs no ashmem at all).
#
# Display architecture (redesigned 2026-07-08): DEFAULT mode is NATIVE — the host KDE
# Wayland socket is bind-mounted into the container and Waydroid's hwcomposer connects
# to KDE DIRECTLY, so Android appears as a NATIVE Plasma window with ONE cursor, native
# touch/trackpad and native audio, zero encode latency (exactly bare-metal
# Waydroid-on-KDE, just Docker-lifecycled). A `stream` mode (headless sway + Sunshine
# VAAPI → Moonlight) and a `vnc` debug mode remain for headless/remote use
# (`waydroid up stream` / `waydroid up vnc`).
#
# Everything (container, boot, native/stream wiring, teardown) is owned by the
# data-driven engine at ~/git/unix/da_waydroid-container/build.sh. The image is built
# in GHA → GHCR (ship-waydroid-container). Baked INTO that image is a self-contained
# launcher (build.json embedded) that `build.sh install` docker-cp's out to
# ~/.local/bin/waydroid — so the launch command is a real binary in the user's bin,
# repo-free. This module: installs that binary (best-effort), provides a KDE launcher
# that prefers it (repo-engine fallback), the client packages, a dedicated icon, and
# the taskbar pin. NO systemd service / autostart / respawn — that was the original
# desktop-session Waydroid's ghost-process class of bug.
{ config, pkgs, lib, ... }:
let
  engine = "$HOME/git/unix/da_waydroid-container/build.sh";
  binary = "$HOME/.local/bin/waydroid";
  desktopId = "waydroid-container";
in {
  # Fallback-transport clients on PATH (native mode needs no client at all; these are
  # only for `up stream` / `up vnc`). Declared here so a menu launch never stalls on
  # the engine's runtime `nix build` fallback (a live failure mode when the nix-daemon
  # socket was frozen). moonlight-qt = stream; tigervnc = vnc.
  home.packages = [ pkgs.moonlight-qt pkgs.tigervnc ];

  # KDE launcher dispatcher. Prefers the self-contained installed binary
  # (~/.local/bin/waydroid, build.json baked in — the portable artifact the user
  # copies into their bin); falls back to the repo engine so there is never a
  # bootstrapping gap before `install` has run. Default action is `up` = native window.
  home.file.".local/bin/waydroid-container" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      BINARY="${binary}"
      ENGINE="${engine}"
      if [ -x "$BINARY" ]; then RUN="$BINARY"
      elif [ -x "$ENGINE" ]; then RUN="$ENGINE"
      else echo "waydroid launcher not installed and engine not found — run: waydroid-container install (or clone ~/git/unix)"; exit 1; fi
      case "''${1:-up}" in
        up|"")  shift 2>/dev/null || true; exec "$RUN" up "$@" ;;
        *)      exec "$RUN" "$@" ;;
      esac
    '';
  };

  # Install the self-contained binary into ~/.local/bin/waydroid from the GHCR image —
  # best-effort, non-fatal, and ONLY if the image is already present locally (never
  # pull during a home-manager switch: that would make activation slow / fail offline).
  # On a fresh machine the user runs `waydroid-container install` once after the first
  # image pull; until then the dispatcher above falls back to the repo engine.
  home.activation.installWaydroidBinary = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if ${pkgs.docker}/bin/docker image inspect ghcr.io/diegonmarcos/waydroid-container:13 >/dev/null 2>&1; then
      run ${engine} install "$HOME/.local/bin" || true
    fi
  '';

  # Dedicated launcher icon (Android-robot-in-a-container motif, Waydroid green) —
  # installed into the hicolor theme so the menu entry, taskbar pin and window all
  # show a distinct icon instead of the generic "smartphone" stock one.
  xdg.dataFile."icons/hicolor/scalable/apps/${desktopId}.svg".text = ''
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
      <rect x="4" y="4" width="56" height="56" rx="12" fill="#1a1a24"/>
      <path d="M22 20 L16 12" stroke="#a4c639" stroke-width="3" stroke-linecap="round"/>
      <path d="M42 20 L48 12" stroke="#a4c639" stroke-width="3" stroke-linecap="round"/>
      <path d="M17 34 a15 15 0 0 1 30 0 z" fill="#a4c639"/>
      <circle cx="25" cy="27" r="2.2" fill="#1a1a24"/>
      <circle cx="39" cy="27" r="2.2" fill="#1a1a24"/>
      <rect x="17" y="37" width="30" height="14" rx="3" fill="#a4c639"/>
      <path d="M10 44 v6 a4 4 0 0 0 4 4 h6 M54 44 v6 a4 4 0 0 1 -4 4 h-6"
            fill="none" stroke="#5f7d8c" stroke-width="3" stroke-linecap="round"/>
      <path d="M10 20 v-6 a4 4 0 0 1 4 -4 h6 M54 20 v-6 a4 4 0 0 0 -4 -4 h-6"
            fill="none" stroke="#5f7d8c" stroke-width="3" stroke-linecap="round"/>
    </svg>
  '';

  # KDE application menu entry. Exec uses an absolute path — desktop-entry Exec does NOT
  # expand `%h`; ~/.local/bin is also not guaranteed on the launcher's PATH.
  xdg.desktopEntries.${desktopId} = {
    name = "Waydroid";
    comment = "Android (Waydroid-in-Docker) — native KDE window (GPU, one cursor, native touch)";
    exec = "${config.home.homeDirectory}/.local/bin/waydroid-container up";
    terminal = false;
    icon = desktopId;
    categories = [ "System" ];
    # KDE matches a running window to a pinned launcher by the window's app-id /
    # WM_CLASS vs the desktop file's StartupWMClass. In the default NATIVE mode the
    # window is Waydroid's own native Wayland toplevel (app-id "Waydroid").
    settings.StartupWMClass = "Waydroid";
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
