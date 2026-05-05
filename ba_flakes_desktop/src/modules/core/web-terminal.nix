# core/web-terminal.nix — web-served terminal (ttyd, mobile-keyboard fork
# via overlay in src/flake.nix)
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    ttyd
  ];
}
