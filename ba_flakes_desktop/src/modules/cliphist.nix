# Clipboard history daemon — records wl-paste events to cliphist DB
# Usage: cliphist list | fzf | cliphist decode | wl-copy
{ config, pkgs, lib, ... }:

{
  systemd.user.services.cliphist = {
    Unit = {
      Description = "Clipboard history recorder (cliphist + wl-paste)";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --watch ${pkgs.cliphist}/bin/cliphist -max-items 0 store";
      Restart = "always";
      RestartSec = 3;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
