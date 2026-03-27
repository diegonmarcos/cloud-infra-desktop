# SSH stale socket cleaner — systemd user timer
# Removes dead ControlMaster mux sockets every 2 minutes
# Prevents stale sockets from blocking SSH after VM resets
{ config, lib, ... }:

{
  home.file.".local/bin/ssh-stale-socket-cleaner" = {
    executable = true;
    source = ./ssh-stale-socket-cleaner.sh;
  };

  systemd.user.services.ssh-stale-socket-cleaner = {
    Unit.Description = "Clean stale SSH ControlMaster sockets";
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/ssh-stale-socket-cleaner";
    };
  };

  systemd.user.timers.ssh-stale-socket-cleaner = {
    Unit.Description = "Clean stale SSH sockets every 2 minutes";
    Timer = {
      OnBootSec = "1min";
      OnUnitActiveSec = "2min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
