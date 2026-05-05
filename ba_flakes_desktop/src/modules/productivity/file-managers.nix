# productivity/file-managers.nix — TUI file managers
# (yazi lives in core/tui.nix as a daily-driver; ranger + mc are alternatives.)
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    ranger
    mc               # Midnight Commander
  ];
}
