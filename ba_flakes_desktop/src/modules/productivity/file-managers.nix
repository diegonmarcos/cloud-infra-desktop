# productivity/file-managers.nix — TUI file managers
# (yazi lives in core/tui.nix as a daily-driver; ranger + mc are alternatives.)
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    ranger
    mc               # Midnight Commander
  ];

  xdg.desktopEntries.mc = {
    name = "Midnight Commander";
    comment = "Terminal file manager with dual-panel interface";
    exec = "mc";
    icon = "system-file-manager";
    terminal = true;
    categories = [ "System" "FileManager" "Utility" ];
  };
}
