# nixos-systray — callPackage-able derivation.
#
# Consumed by:
#   aa_desk-usr_x86_surface-linux_nixos/src/modules/configuration_nixos-switch-gui.nix
#   via pkgs.callPackage ../../../../da_nixos-systray/src/nix/package.nix { src = ...; ... }
#
# WHY plain callPackage instead of a flake input: nix 2.24 cannot lock/re-fetch
# relative-path flake inputs inside a git flake. Revisit when nix >= 2.26.
{ stdenv, src, bash, konsole, xdg-utils, kdialog, qdbus,
  electron, nodejs, typescript, librsvg,
  makeWrapper, makeDesktopItem, lib }:

let
  desktopItem = makeDesktopItem {
    name         = "nixos-systray";
    desktopName  = "NixOS Control Panel";
    comment      = "Rebuild & manage NixOS — switch, dry-run, update, logs, settings";
    exec         = "nixos-systray --show";
    icon         = "nixos-systray";
    categories   = [ "System" ];
    terminal     = false;
    startupNotify = false;
  };
in
stdenv.mkDerivation {
  pname   = "nixos-systray";
  version = "1.0.0";
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
    install -Dm644 src/scripts/dist/main.js  $out/lib/nixos-systray/main.js
    install -Dm644 src/scripts/panel.html    $out/lib/nixos-systray/panel.html

    # Data + assets
    install -Dm644 src/data/nixos-cp.json    $out/share/nixos-systray/nixos-cp.json
    # SVG → PNG: Electron Tray on Linux only supports raster formats
    mkdir -p $out/share/icons/hicolor/128x128/apps $out/share/icons/hicolor/scalable/apps
    rsvg-convert -w 128 -h 128 src/assets/nixos-systray.svg \
      -o $out/share/icons/hicolor/128x128/apps/nixos-systray.png
    install -Dm644 src/assets/nixos-systray.svg \
      $out/share/icons/hicolor/scalable/apps/nixos-systray.svg

    # switch-gui.sh (kdialog progress window, separate binary)
    install -Dm755 src/scripts/switch-gui.sh $out/bin/nixos-switch-gui
    substituteInPlace $out/bin/nixos-switch-gui \
      --replace '@DATA@'    "$out/share/nixos-systray/nixos-cp.json" \
      --replace '@BASH@'    '${bash}/bin/bash'         \
      --replace '@KDIALOG@' '${kdialog}/bin/kdialog'   \
      --replace '@QDBUS@'   '${qdbus}/bin/qdbus6'

    # Desktop item
    mkdir -p $out/share/applications
    cp ${desktopItem}/share/applications/nixos-systray.desktop $out/share/applications/

    # Main binary: electron wrapper with all paths as env vars
    makeWrapper ${electron}/bin/electron $out/bin/nixos-systray \
      --add-flags "$out/lib/nixos-systray/main.js" \
      --set SYSTRAY_DATA       "$out/share/nixos-systray/nixos-cp.json" \
      --set SYSTRAY_ICON       "$out/share/icons/hicolor/128x128/apps/nixos-systray.png" \
      --set SYSTRAY_SWITCH_GUI "$out/bin/nixos-switch-gui" \
      --set SYSTRAY_BASH       "${bash}/bin/bash" \
      --set SYSTRAY_KONSOLE    "${konsole}/bin/konsole" \
      --set SYSTRAY_XDG        "${xdg-utils}/bin/xdg-open" \
      --set-default ELECTRON_OZONE_PLATFORM_HINT "auto"
    # SYSTRAY_FLAKE is set by the systemd unit (points to the live flake checkout)

    runHook postInstall
  '';

  meta.description = "NixOS Control Panel system tray (Electron, native SNI)";
  meta.mainProgram  = "nixos-systray";
}
