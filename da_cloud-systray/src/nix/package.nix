# cloud-systray — callPackage-able derivation.
#
# Consumed by:
#   aa_desk-usr_x86_surface-linux_nixos/src/modules/configuration_cloud-cp.nix
#   via pkgs.callPackage ../../../../da_cloud-systray/src/nix/package.nix { src = ...; }
#
# WHY plain callPackage instead of a flake input: nix 2.24 cannot lock/re-fetch
# relative-path flake inputs inside a git flake. Revisit when nix >= 2.26.
{ stdenv, src, bash, konsole, xdg-utils,
  electron, nodejs, typescript,
  makeWrapper, makeDesktopItem, lib }:

let
  desktopItem = makeDesktopItem {
    name         = "cloud-systray";
    desktopName  = "Cloud & Infra Control Panel";
    comment      = "Monitor VMs, services, mesh, and flake builds";
    exec         = "cloud-systray";
    icon         = "cloud-systray";
    categories   = [ "System" "Network" ];
    terminal     = false;
    startupNotify = false;
  };
in
stdenv.mkDerivation {
  pname   = "cloud-systray";
  version = "1.0.0";
  inherit src;

  nativeBuildInputs = [ nodejs typescript makeWrapper ];

  buildPhase = ''
    cd src/scripts

    tsc
    cd ../..
  '';

  installPhase = ''
    runHook preInstall

    # Compiled JS + HTML panel
    install -Dm644 src/scripts/dist/main.js  $out/lib/cloud-systray/main.js
    install -Dm644 src/scripts/panel.html    $out/lib/cloud-systray/panel.html

    # Data + assets
    install -Dm644 src/data/cloud-cp.json    $out/share/cloud-systray/cloud-cp.json
    install -Dm644 src/assets/cloud-systray.svg \
      $out/share/icons/hicolor/scalable/apps/cloud-systray.svg

    # Desktop item
    mkdir -p $out/share/applications
    cp ${desktopItem}/share/applications/cloud-systray.desktop $out/share/applications/

    # Main binary: electron wrapper with all paths as env vars
    makeWrapper ${electron}/bin/electron $out/bin/cloud-systray \
      --add-flags "$out/lib/cloud-systray/main.js" \
      --set SYSTRAY_DATA          "$out/share/cloud-systray/cloud-cp.json" \
      --set SYSTRAY_ICON          "$out/share/icons/hicolor/scalable/apps/cloud-systray.svg" \
      --set SYSTRAY_BASH          "${bash}/bin/bash" \
      --set SYSTRAY_KONSOLE       "${konsole}/bin/konsole" \
      --set SYSTRAY_XDG           "${xdg-utils}/bin/xdg-open" \
      --set-default ELECTRON_OZONE_PLATFORM_HINT "auto"
    # SYSTRAY_FLAKE_SYSTEM / _DESKTOP / _CLOUD set by the systemd unit

    runHook postInstall
  '';

  meta.description = "Cloud & Infra Control Panel system tray (Electron, native SNI)";
  meta.mainProgram  = "cloud-systray";
}
