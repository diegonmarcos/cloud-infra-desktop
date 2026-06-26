# nixos-systray — callPackage-able derivation.
#
# Consumed by:
#   aa_desk-usr_x86_surface-linux_nixos/src/modules/configuration_nixos-switch-gui.nix
#   via pkgs.callPackage ../../../../da_nixos-systray/src/nix/package.nix { src = ...; ... }
#
# WHY plain callPackage instead of a flake input: nix 2.24 cannot lock/re-fetch
# relative-path flake inputs inside a git flake. Revisit when nix >= 2.26.
{ stdenvNoCC, src, jq, yad, bash, konsole, xdg-utils, kdialog, qdbus, makeDesktopItem, lib }:

let
  desktopItem = makeDesktopItem {
    name         = "nixos-systray";
    desktopName  = "NixOS Control Panel";
    comment      = "Rebuild & manage NixOS — switch, dry-run, update, logs, settings";
    exec         = "nixos-systray";
    icon         = "nixos-systray";
    categories   = [ "System" ];
    terminal     = false;
    startupNotify = false;
  };
in
stdenvNoCC.mkDerivation {
  pname   = "nixos-systray";
  version = "1.0.0";
  inherit src;   # passed from callPackage — avoids pure eval path restriction

  dontConfigure = true;
  dontBuild     = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 src/scripts/tray.sh       $out/bin/nixos-systray
    install -Dm755 src/scripts/switch-gui.sh $out/bin/nixos-switch-gui
    install -Dm755 src/scripts/cp-window.sh  $out/bin/nixos-cp-window
    install -Dm644 src/data/nixos-cp.json    $out/share/nixos-systray/nixos-cp.json
    install -Dm644 src/assets/nixos-systray.svg \
      $out/share/icons/hicolor/scalable/apps/nixos-systray.svg

    # Desktop item
    mkdir -p $out/share/applications
    cp ${desktopItem}/share/applications/nixos-systray.desktop $out/share/applications/

    # Bake nix store paths into scripts
    substituteInPlace $out/bin/nixos-systray \
      --replace '@DATA@'    "$out/share/nixos-systray/nixos-cp.json" \
      --replace '@JQ@'      '${jq}/bin/jq'          \
      --replace '@YAD@'     '${yad}/bin/yad'         \
      --replace '@BASH@'    '${bash}/bin/bash'       \
      --replace '@KONSOLE@' '${konsole}/bin/konsole' \
      --replace '@XDG@'     '${xdg-utils}/bin/xdg-open'

    substituteInPlace $out/bin/nixos-switch-gui \
      --replace '@DATA@'    "$out/share/nixos-systray/nixos-cp.json" \
      --replace '@JQ@'      '${jq}/bin/jq'            \
      --replace '@BASH@'    '${bash}/bin/bash'         \
      --replace '@KDIALOG@' '${kdialog}/bin/kdialog'   \
      --replace '@QDBUS@'   '${qdbus}/bin/qdbus6'

    substituteInPlace $out/bin/nixos-cp-window \
      --replace '@DATA@'    "$out/share/nixos-systray/nixos-cp.json" \
      --replace '@JQ@'      '${jq}/bin/jq'            \
      --replace '@YAD@'     '${yad}/bin/yad'           \
      --replace '@BASH@'    '${bash}/bin/bash'

    runHook postInstall
  '';

  meta.description = "NixOS Control Panel system tray and switch GUI";
  meta.mainProgram  = "nixos-systray";
}
