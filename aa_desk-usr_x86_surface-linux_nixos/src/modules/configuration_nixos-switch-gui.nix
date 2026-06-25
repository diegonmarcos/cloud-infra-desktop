# NixOS Control Panel — a Qt6 (PySide6) system-tray app with a dark UI to
# rebuild & manage the host: grouped submenus (data-driven from
# /etc/nixos-cp.json), real dark Qt progress windows with a live log + parsed
# progress bar, GUI sudo via ksshaskpass (so build.sh's `sudo nixos-rebuild`
# works without a TTY). Auto-starts in the graphical session and stays in the
# tray. App source: ./nixos_cp.py ; menu: ./nixos-cp.json.
{ config, lib, pkgs, ... }:

let
  flakeDir = "/home/diego/git/unix/aa_desk-usr_x86_surface-linux_nixos";

  pyEnv = pkgs.python3.withPackages (ps: [ ps.pyside6 ]);

  nixos-cp = pkgs.writeShellScriptBin "nixos-cp" ''
    # /run/wrappers/bin first so `sudo` resolves to the setuid wrapper (needed
    # for the GUI `sudo -A -v` pre-auth). current-system gives konsole/xdg-open.
    export PATH="/run/wrappers/bin:/run/current-system/sw/bin:$PATH"
    export SUDO_ASKPASS="${pkgs.ksshaskpass}/bin/ksshaskpass"
    export NIXOS_CP_CONF="/etc/nixos-cp.json"
    export NIXOS_CP_FLAKE="${flakeDir}"
    # Prefer Wayland, fall back to XWayland.
    export QT_QPA_PLATFORM="''${QT_QPA_PLATFORM:-wayland;xcb}"
    exec ${pyEnv}/bin/python3 ${./nixos_cp.py} "$@"
  '';

  cpItem = pkgs.makeDesktopItem {
    name = "nixos-cp";
    desktopName = "NixOS Control Panel";
    comment = "Rebuild & manage NixOS — switch, dry-run, update, logs, settings";
    exec = "${nixos-cp}/bin/nixos-cp";
    icon = "nix-snowflake";
    categories = [ "System" ];
    terminal = false;
    startupNotify = false;
  };

in {
  environment.systemPackages = [ nixos-cp cpItem pkgs.ksshaskpass ];

  # Menu definition lives in /etc so the app reads it at runtime (edit the flake
  # JSON -> rebuild -> menu updates). Data-driven.
  environment.etc."nixos-cp.json".source = ./nixos-cp.json;

  # Tray auto-starts in the graphical session; respawns if it dies. Single-
  # instance lock in the app prevents a second tray icon.
  systemd.user.services.nixos-cp-tray = {
    description = "NixOS Control Panel tray icon";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${nixos-cp}/bin/nixos-cp";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
