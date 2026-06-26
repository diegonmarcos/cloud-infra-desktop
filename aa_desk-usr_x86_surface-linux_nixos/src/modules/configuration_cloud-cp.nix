# cloud-systray — thin NixOS system module.
#
# Package source: da_cloud-systray/src/nix/package.nix (callPackage)
# Script:         da_cloud-systray/src/scripts/tray.sh
# Menu data:      da_cloud-systray/src/data/cloud-cp.json
# Assets:         da_cloud-systray/src/assets/
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
      # Wait until XWayland has created the X11 socket (up to 60s)
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in $(seq 60); do [ -S /tmp/.X11-unix/X0 ] && exit 0; sleep 1; done; exit 1'";
      ExecStart    = "${cloud-systray-pkg}/bin/cloud-systray";
      # Only provide what the script cannot discover itself.
      # DISPLAY, XAUTHORITY, WAYLAND_DISPLAY, GDK_BACKEND are all handled
      # by the script's own discovery block — do NOT override them here or
      # XAUTHORITY will be skipped and X will reject the connection.
      Environment  = [
        "XDG_RUNTIME_DIR=/run/user/1000"
        "XDG_CURRENT_DESKTOP=KDE"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
        "NO_AT_BRIDGE=1"
      ];
      Restart    = "on-failure";
      RestartSec = 10;
    };
  };
}
