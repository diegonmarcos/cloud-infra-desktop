# productivity/tasks-time.nix — task tracking + calendar/reminder CLIs
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    taskwarrior
    vit              # Visual task interface
    calcurse
    remind
  ];
}
