# cloud-systray — thin NixOS system module.
#
# Package source: da_cloud-systray/src/nix/package.nix (callPackage)
# Script:         da_cloud-systray/src/scripts/main.ts (compiled to main.js)
# Menu data:      da_cloud-systray/src/data/cloud-cp.json
# Assets:         da_cloud-systray/src/assets/
#
# This file owns ONLY: system package registration + systemd user service.
# No inline scripts. No inlined menu data.
{ config, lib, pkgs, ... }:

let
  cloud-systray-pkg = pkgs.callPackage ../../../da_cloud-systray/src/nix/package.nix {
    src = ../../../da_cloud-systray;
  };
in {
  environment.systemPackages = [ cloud-systray-pkg ];

  systemd.user.services.cloud-systray = {
    description = "Cloud & Infra Control Panel tray icon";
    # NO autostart — electron tray must not be launched by systemd at login
    # (it fought the freeze-guard watchdog and ate RAM). Start manually if wanted:
    # `systemctl --user start cloud-systray`. Service stays defined, just not wired
    # into graphical-session.target.
    wantedBy    = [ ];
    partOf      = [ "graphical-session.target" ];
    after       = [ "graphical-session.target" ];
    serviceConfig = {
      # Wait until the Wayland compositor socket appears (Electron uses Wayland via
      # ELECTRON_OZONE_PLATFORM_HINT=auto; no XWayland needed).
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in $(seq 60); do [ -S \"/run/user/1000/wayland-0\" ] || [ -S \"/run/user/1000/wayland-1\" ] && exit 0; sleep 1; done; exit 1'";
      ExecStart    = "${cloud-systray-pkg}/bin/cloud-systray";
      Environment  = [
        "XDG_RUNTIME_DIR=/run/user/1000"
        "XDG_CURRENT_DESKTOP=KDE"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
        "NO_AT_BRIDGE=1"
        # Flake paths for log discovery and build commands
        "SYSTRAY_FLAKE_SYSTEM=/home/diego/git/unix/aa_desk-usr_x86_surface-linux_nixos"
        "SYSTRAY_FLAKE_DESKTOP=/home/diego/git/unix/ba_flakes_desktop"
        "SYSTRAY_FLAKE_CLOUD=/home/diego/git/cloud"
      ];
      Restart    = "on-failure";
      RestartSec = 10;
    };
  };
}
