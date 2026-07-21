# workflow-systray — callPackage-able derivation.
#
# Consumed by:
#   aa_desk-usr_x86_surface-linux_nixos/src/modules/configuration_workflow-systray.nix
#   via pkgs.callPackage ../../../../da_workflow-systray/src/nix/package.nix { src = ...; }
#
# WHY plain callPackage instead of a flake input: nix 2.24 cannot lock/re-fetch
# relative-path flake inputs inside a git flake. Revisit when nix >= 2.26.
{ stdenv, src, bash, konsole, xdg-utils, gh,
  electron, nodejs, typescript, librsvg,
  makeWrapper, makeDesktopItem, lib }:

let
  desktopItem = makeDesktopItem {
    name         = "workflow-systray";
    desktopName  = "Workflow Control Panel";
    comment      = "GitHub Actions status + Dagu DAG trigger/monitor";
    exec         = "workflow-systray --show";
    icon         = "workflow-systray";
    categories   = [ "System" "Network" ];
    terminal     = false;
    startupNotify = false;
  };
in
stdenv.mkDerivation {
  pname   = "workflow-systray";
  version = "0.1.0";
  inherit src;

  nativeBuildInputs = [ nodejs typescript makeWrapper librsvg ];

  buildPhase = ''
    cd src/scripts

    tsc
    cd ../..
  '';

  installPhase = ''
    runHook preInstall

    # Compiled JS + HTML panel
    install -Dm644 src/scripts/dist/main.js  $out/lib/workflow-systray/main.js
    install -Dm644 src/scripts/panel.html    $out/lib/workflow-systray/panel.html

    # Data + assets
    install -Dm644 src/data/workflow-cp.json $out/share/workflow-systray/workflow-cp.json
    # SVG → PNG: Electron Tray on Linux only supports raster formats
    mkdir -p $out/share/icons/hicolor/128x128/apps $out/share/icons/hicolor/scalable/apps
    rsvg-convert -w 128 -h 128 src/assets/workflow-systray.svg \
      -o $out/share/icons/hicolor/128x128/apps/workflow-systray.png
    install -Dm644 src/assets/workflow-systray.svg \
      $out/share/icons/hicolor/scalable/apps/workflow-systray.svg

    # Desktop item
    mkdir -p $out/share/applications
    cp ${desktopItem}/share/applications/workflow-systray.desktop $out/share/applications/

    # Main binary: electron wrapper with all paths as env vars
    makeWrapper ${electron}/bin/electron $out/bin/workflow-systray \
      --add-flags "$out/lib/workflow-systray/main.js" \
      --set SYSTRAY_DATA          "$out/share/workflow-systray/workflow-cp.json" \
      --set SYSTRAY_ICON          "$out/share/icons/hicolor/128x128/apps/workflow-systray.png" \
      --set SYSTRAY_BASH          "${bash}/bin/bash" \
      --set SYSTRAY_KONSOLE       "${konsole}/bin/konsole" \
      --set SYSTRAY_XDG           "${xdg-utils}/bin/xdg-open" \
      --set SYSTRAY_GH            "${gh}/bin/gh" \
      --set-default ELECTRON_OZONE_PLATFORM_HINT "x11"
      # x11, not auto (2026-07-18): same fix as da_nixos-systray/src/nix/package.nix and
      # da_cloud-systray/src/nix/package.nix — "auto" resolves to Wayland Ozone on this
      # native-Wayland Plasma session, and Electron's Tray API has no Wayland Ozone
      # implementation, so it exits 1 immediately and crash-loops under systemd. x11 runs
      # it under XWayland where GTK tray + xembedsniproxy work.
    # SYSTRAY_DATA_PATH is an alias env var some future consumer may read; main.ts
    # resolves the data file from SYSTRAY_DATA (matches the other two trays' convention).

    runHook postInstall
  '';

  meta.description = "Workflow Control Panel system tray — GHA status + Dagu (Electron, native SNI)";
  meta.mainProgram  = "workflow-systray";
}
