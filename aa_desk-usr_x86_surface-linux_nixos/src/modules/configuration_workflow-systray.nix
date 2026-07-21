# workflow-systray — thin NixOS system module.
#
# Package source: da_workflow-systray/src/nix/package.nix (callPackage)
# Script:         da_workflow-systray/src/scripts/main.ts (compiled to main.js)
# Menu data:      da_workflow-systray/src/data/workflow-cp.json
# Assets:         da_workflow-systray/src/assets/
#
# This file owns ONLY: system package registration + systemd user service.
# No inline scripts. No inlined menu data.
{ config, lib, pkgs, ... }:

let
  workflow-systray-pkg = pkgs.callPackage ../../../da_workflow-systray/src/nix/package.nix {
    src = ../../../da_workflow-systray;
  };
in {
  environment.systemPackages = [ workflow-systray-pkg ];

  systemd.user.services.workflow-systray = {
    description = "Workflow Control Panel tray icon (GHA + Dagu)";
    # NO autostart — electron tray must not be launched by systemd at login
    # (matches cloud-systray/nixos-systray precedent — fought the freeze-guard
    # watchdog and ate RAM). Start manually if wanted:
    # `systemctl --user start workflow-systray`. Service stays defined, just
    # not wired into graphical-session.target.
    wantedBy    = [ ];
    partOf      = [ "graphical-session.target" ];
    after       = [ "graphical-session.target" ];
    serviceConfig = {
      # Wait until the Wayland compositor socket appears (Electron itself runs
      # under XWayland via ELECTRON_OZONE_PLATFORM_HINT=x11, set in package.nix,
      # but still needs the session to be up before launching).
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in $(seq 60); do [ -S \"/run/user/1000/wayland-0\" ] || [ -S \"/run/user/1000/wayland-1\" ] && exit 0; sleep 1; done; exit 1'";
      ExecStart    = "${workflow-systray-pkg}/bin/workflow-systray";
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
