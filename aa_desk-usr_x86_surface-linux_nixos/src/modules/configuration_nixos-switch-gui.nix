# nixos-systray + nixos-switch-gui — thin NixOS system module.
#
# Package source: da_nixos-systray/src/nix/package.nix (callPackage)
# Scripts:        da_nixos-systray/src/scripts/
# Menu data:      da_nixos-systray/src/data/nixos-cp.json
#
# This file owns ONLY: system package registration + systemd user service.
# No inline scripts. No inlined menu data.
{ config, lib, pkgs, ... }:

let
  nixos-systray-pkg = pkgs.callPackage ../../../../da_nixos-systray/src/nix/package.nix {
    src = ../../../../da_nixos-systray;
  };
in {
  environment.systemPackages = [ nixos-systray-pkg ];

  systemd.user.services.nixos-systray = {
    description = "NixOS Control Panel tray icon";
    wantedBy    = [ "graphical-session.target" ];
    partOf      = [ "graphical-session.target" ];
    after       = [ "graphical-session.target" ];
    serviceConfig = {
      # Wait for Plasma's StatusNotifierWatcher to register on D-Bus
      ExecStartPre       = "${pkgs.coreutils}/bin/sleep 5";
      ExecStart          = "${nixos-systray-pkg}/bin/nixos-systray";
      UnsetEnvironment   = [ "WAYLAND_DISPLAY" ];
      Environment  = [
        "DISPLAY=:0"
        "GDK_BACKEND=x11"
        "XDG_RUNTIME_DIR=/run/user/1000"
        "XDG_CURRENT_DESKTOP=KDE"
        "NO_AT_BRIDGE=1"
      ];
      Restart    = "on-failure";
      RestartSec = 10;
    };
  };
}
