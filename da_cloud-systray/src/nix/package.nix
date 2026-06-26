# cloud-systray — callPackage-able derivation.
#
# Consumed by:
#   aa_desk-usr_x86_surface-linux_nixos/src/modules/configuration_cloud-cp.nix
#   via pkgs.callPackage ../../../../da_cloud-systray/src/nix/package.nix { src = ...; }
#
# WHY plain callPackage instead of a flake input: nix 2.24 cannot lock/re-fetch
# relative-path flake inputs inside a git flake. Revisit when nix >= 2.26.
{ stdenvNoCC, src, jq, yad, bash, konsole, xdg-utils, makeDesktopItem, lib }:

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
stdenvNoCC.mkDerivation {
  pname   = "cloud-systray";
  version = "1.0.0";
  inherit src;   # passed from callPackage — avoids pure eval path restriction

  dontConfigure = true;
  dontBuild     = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 src/scripts/tray.sh    $out/bin/cloud-systray
    install -Dm644 src/data/cloud-cp.json $out/share/cloud-systray/cloud-cp.json
    install -Dm644 src/assets/cloud-systray.svg \
      $out/share/icons/hicolor/scalable/apps/cloud-systray.svg

    # Desktop item
    mkdir -p $out/share/applications
    cp ${desktopItem}/share/applications/cloud-systray.desktop $out/share/applications/

    # Bake nix store paths into script
    substituteInPlace $out/bin/cloud-systray \
      --replace '@DATA@'    "$out/share/cloud-systray/cloud-cp.json" \
      --replace '@JQ@'      '${jq}/bin/jq'          \
      --replace '@YAD@'     '${yad}/bin/yad'         \
      --replace '@BASH@'    '${bash}/bin/bash'        \
      --replace '@KONSOLE@' '${konsole}/bin/konsole'  \
      --replace '@XDG@'     '${xdg-utils}/bin/xdg-open'

    runHook postInstall
  '';

  meta.description = "Cloud & Infra Control Panel system tray";
  meta.mainProgram  = "cloud-systray";
}
