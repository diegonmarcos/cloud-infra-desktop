# nixos-systray + nixos-switch-gui — thin NixOS system module.
#
# Package source: da_nixos-systray/src/nix/package.nix (callPackage)
# Scripts:        da_nixos-systray/src/scripts/
# Menu data:      da_nixos-systray/src/data/nixos-cp.json
# Assets:         da_nixos-systray/src/assets/
#
# This file owns ONLY: system package registration + systemd user service.
# No inline scripts. No inlined menu data.
{ config, lib, pkgs, ... }:

let
  nixos-systray-pkg = pkgs.callPackage ../../../da_nixos-systray/src/nix/package.nix {
    src      = ../../../da_nixos-systray;
    kdialog  = pkgs.kdePackages.kdialog;
    qdbus    = pkgs.kdePackages.qttools;
  };
in {
  environment.systemPackages = [ nixos-systray-pkg ];

  systemd.user.services.nixos-systray = {
    description = "NixOS Control Panel tray icon";
    wantedBy    = [ "graphical-session.target" ];
    partOf      = [ "graphical-session.target" ];
    after       = [ "graphical-session.target" ];
    serviceConfig = {
      # Wait until the Wayland compositor socket appears (Electron uses Wayland via
      # ELECTRON_OZONE_PLATFORM_HINT=auto; no XWayland needed).
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in $(seq 60); do [ -S \"/run/user/1000/wayland-0\" ] || [ -S \"/run/user/1000/wayland-1\" ] && exit 0; sleep 1; done; exit 1'";
      ExecStart    = "${nixos-systray-pkg}/bin/nixos-systray";
      Environment  = [
        "XDG_RUNTIME_DIR=/run/user/1000"
        "XDG_CURRENT_DESKTOP=KDE"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
        "NO_AT_BRIDGE=1"
        # Flake path for log file discovery (tooltip + log viewer)
        "SYSTRAY_FLAKE=/home/diego/git/unix/aa_desk-usr_x86_surface-linux_nixos"
      ];
      Restart    = "on-failure";
      RestartSec = 10;
    };
  };
}
