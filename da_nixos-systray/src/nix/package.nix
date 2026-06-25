# nixos-systray — callPackage-able derivation.
#
# Consumed by:
#   aa_desk-usr_x86_surface-linux_nixos/src/modules/configuration_nixos-switch-gui.nix
#   via pkgs.callPackage ../../../../da_nixos-systray/src/nix/package.nix {}
#
# WHY plain callPackage instead of a flake input: nix 2.24 cannot lock/re-fetch
# relative-path flake inputs inside a git flake. Same workaround as
# da_fido2-vault-broker. Revisit when nix >= 2.26.
{ stdenvNoCC, jq, yad, bash, konsole, xdg-utils, makeDesktopItem, lib }:

let
  desktopItem = makeDesktopItem {
    name         = "nixos-systray";
    desktopName  = "NixOS Control Panel";
    comment      = "Rebuild & manage NixOS — switch, dry-run, update, logs, settings";
    exec         = "nixos-systray";
    icon         = "nix-snowflake";
    categories   = [ "System" ];
    terminal     = false;
    startupNotify = false;
  };
in
stdenvNoCC.mkDerivation {
  pname   = "nixos-systray";
  version = "1.0.0";
  src     = ../..;   # da_nixos-systray root

  dontConfigure = true;
  dontBuild     = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 src/scripts/tray.sh       $out/bin/nixos-systray
    install -Dm755 src/scripts/switch-gui.sh $out/bin/nixos-switch-gui
    install -Dm644 src/data/nixos-cp.json    $out/share/nixos-systray/nixos-cp.json

    # Desktop item
    mkdir -p $out/share/applications
    cp ${desktopItem}/share/applications/nixos-systray.desktop $out/share/applications/

    # Substitute nix store paths (user-data paths come from the JSON at runtime)
    substituteInPlace $out/bin/nixos-systray \
      --replace '@DATA@'    "$out/share/nixos-systray/nixos-cp.json" \
      --replace '@JQ@'      '${jq}/bin/jq'       \
      --replace '@YAD@'     '${yad}/bin/yad'      \
      --replace '@BASH@'    '${bash}/bin/bash'    \
      --replace '@KONSOLE@' '${konsole}/bin/konsole' \
      --replace '@XDG@'     '${xdg-utils}/bin/xdg-open'

    substituteInPlace $out/bin/nixos-switch-gui \
      --replace '@DATA@'    "$out/share/nixos-systray/nixos-cp.json" \
      --replace '@JQ@'      '${jq}/bin/jq'       \
      --replace '@BASH@'    '${bash}/bin/bash'    \
      --replace '@KONSOLE@' '${konsole}/bin/konsole'

    runHook postInstall
  '';

  meta.description = "NixOS Control Panel system tray and switch GUI";
  meta.mainProgram  = "nixos-systray";
}
