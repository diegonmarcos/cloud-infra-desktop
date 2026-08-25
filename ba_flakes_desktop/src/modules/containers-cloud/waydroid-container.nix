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
# data-driven engine at ~/git/cloud-unix/da_waydroid-container/build.sh. The image is built
# in GHA → GHCR (ship-waydroid-container). Baked INTO that image is a self-contained
# launcher (build.json embedded) that `build.sh install` docker-cp's out to
# ~/.local/bin/waydroid — so the launch command is a real binary in the user's bin,
# repo-free. This module: installs that binary (best-effort), provides a KDE launcher
# that prefers it (repo-engine fallback), the client packages, a dedicated icon, and
# the taskbar pin. NO systemd service / autostart / respawn — that was the original
# desktop-session Waydroid's ghost-process class of bug.
{ config, pkgs, lib, ... }:
let
  engine = "$HOME/git/cloud-unix/da_waydroid-container/build.sh";
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

  # Dedicated launcher icon — the SAME adaptive-icon design as every aa_cloud-* app
  # (background #0A0A0A + bold white brand glyph + translucent cloud-tick badge),
  # ported 1:1 from aa_cloud-superapp/app/src/main/res/{drawable,mipmap-anydpi-v26}
  # /ic_launcher*.xml pathData to SVG (VectorDrawable path syntax === SVG path syntax,
  # same nonzero fill-rule, so the glyph's counter/hole reproduces without edits) —
  # installed into the hicolor theme so the menu entry, taskbar pin and window all
  # show the fleet's own branding instead of the generic "smartphone" stock icon.
  xdg.dataFile."icons/hicolor/scalable/apps/${desktopId}.svg".text = ''
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108" width="108" height="108">
      <path fill="#0A0A0A" d="M0,0h108v108h-108z"/>
      <path fill="#FFFFFF" d="M36,30 L36,78 L56,78 C70.36,78 78,69.04 78,54 C78,38.96 70.36,30 56,30 Z M46,40 L56,40 C64.84,40 68,46.16 68,54 C68,61.84 64.84,68 56,68 L46,68 Z"/>
      <g transform="translate(68.6,20.6) scale(0.62)">
        <path fill="#FFFFFF" fill-opacity="0.949" d="M19.35,10.04C18.67,6.59 15.64,4 12,4 9.11,4 6.6,5.64 5.35,8.04 2.34,8.36 0,10.91 0,14c0,3.31 2.69,6 6,6h13c2.76,0 5,-2.24 5,-5 0,-2.64 -2.05,-4.78 -4.65,-4.96z"/>
      </g>
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

  # Second launcher, same container, different VIEWPORT. `up` with no form takes
  # build.json's display.form_default (tablet, 2304x1536 @225dpi -> sw1365dp -> tablet
  # layouts); `up mobile` is 1080x2400 @420dpi -> sw514dp, i.e. under the sw600dp
  # breakpoint, so Android draws phone layouts in a phone-shaped window. Same icon and
  # the same StartupWMClass on purpose: it is one Android, and the KWin
  # waydroid-default-desktop rule (window-rules.json) sends either form to Desk4.
  # Waydroid fixes its resolution when the SESSION starts, so switching form restarts
  # the container — the engine does that, and a form already applied costs nothing.
  xdg.desktopEntries."${desktopId}-mobile" = {
    name = "Waydroid (Phone)";
    comment = "Android (Waydroid-in-Docker) in the phone viewport — 1080x2400, phone layouts";
    exec = "${config.home.homeDirectory}/.local/bin/waydroid-container up mobile";
    terminal = false;
    icon = desktopId;
    categories = [ "System" ];
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
  #   2. It is redundant. panels.json owns the launcher row declaratively
  #      and lists waydroid-container as its 9th entry, so an imperative hook
  #      pinning one app behind the declarative list's back can only fight it.
  #
  # Add or reorder launchers in modules/desktop/panels.json, nowhere else.
}
