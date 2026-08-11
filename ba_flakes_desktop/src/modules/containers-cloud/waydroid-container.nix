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
  # On PATH so a menu launch never stalls on the engine's runtime `nix build` fallback
  # (a live failure mode when the nix-daemon socket was frozen). kdotool: KWin/Wayland
  # window query — native mode uses it for the close-window ⇒ stop-container lifecycle
  # (X11 xdotool can't see the native Wayland toplevel). moonlight-qt = stream transport,
  # tigervnc = vnc transport (native mode needs neither).
  home.packages = [ pkgs.kdotool pkgs.moonlight-qt pkgs.tigervnc ];

  # KDE launcher dispatcher. Prefers the self-contained installed binary
  # (~/.local/bin/waydroid, build.json baked in — the portable artifact the user
  # copies into their bin); falls back to the repo engine so there is never a
  # bootstrapping gap before `install` has run. Default action is `up` = native window.
  home.file.".local/bin/waydroid-container" = {
    executable = true;
    text = builtins.replaceStrings [ "@binary@"  "@engine@" ] [ binary  engine ]
      (builtins.readFile ./scripts/waydroid-container.sh);
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

  # No taskbar pin here. It used to live in this file as
  # home.activation.pinWaydroidContainerTaskbar and was removed 2026-08-11 for
  # two reasons:
  #
  #   1. It wrote to [Containments][N][Applets][M][Config][General] -- "Config",
  #      not "Configuration". plasmashell reads launchers from
  #      [Configuration][General], so the key it wrote was inert, and because it
  #      READ from the same wrong group its "append to current" always saw an
  #      empty list and wrote a single-entry one. The live appletsrc still has
  #      the bogus [Config][General] section it left behind.
  #   2. It is redundant. bottom-panel.json owns the launcher row declaratively
  #      and lists waydroid-container as its 9th entry, so an imperative hook
  #      pinning one app behind the declarative list's back can only fight it.
  #
  # Add or reorder launchers in bottom-panel.json, nowhere else.
}
