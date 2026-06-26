# cloud-systray — thin NixOS system module.
#
# Package source: da_cloud-systray/src/nix/package.nix (callPackage)
# Script:         da_cloud-systray/src/scripts/tray.sh
# Menu data:      da_cloud-systray/src/data/cloud-cp.json
#
# This file owns ONLY: system package registration + systemd user service.
# No inline scripts. No inlined menu data.
{ config, lib, pkgs, ... }:

let
  cloud-systray-pkg = pkgs.callPackage ../../../../da_cloud-systray/src/nix/package.nix {
    src = ../../../../da_cloud-systray;
  };
in {
  environment.systemPackages = [ cloud-systray-pkg ];

  systemd.user.services.cloud-systray = {
    description = "Cloud & Infra Control Panel tray icon";
    wantedBy    = [ "graphical-session.target" ];
    partOf      = [ "graphical-session.target" ];
    after       = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStartPre       = "${pkgs.coreutils}/bin/sleep 5";
      ExecStart          = "${cloud-systray-pkg}/bin/cloud-systray";
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
