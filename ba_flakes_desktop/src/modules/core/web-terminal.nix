# core/web-terminal.nix — web-served terminal (ttyd, mobile-keyboard fork
# via overlay in src/flake.nix)
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    ttyd
  ];

  xdg.desktopEntries.ttyd = {
    name = "ttyd Web Terminal";
    comment = "Share terminal over the web";
    exec = "ttyd bash";
    icon = "utilities-terminal";
    terminal = false;
    categories = [ "System" "Network" ];
  };
}
