# productivity/tasks-time.nix — task tracking + calendar/reminder CLIs
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    taskwarrior3
    vit              # Visual task interface
    calcurse
    remind
  ];

  xdg.desktopEntries = {
    vit = {
      name = "Vit (Task Warrior)";
      comment = "Visual interface for Taskwarrior";
      exec = "vit";
      icon = "utilities-terminal";
      terminal = true;
      categories = [ "Office" "Utility" ];
    };
    calcurse = {
      name = "Calcurse";
      comment = "Terminal calendar and todo list";
      exec = "calcurse";
      icon = "office-calendar";
      terminal = true;
      categories = [ "Office" "Calendar" ];
    };
  };
}
