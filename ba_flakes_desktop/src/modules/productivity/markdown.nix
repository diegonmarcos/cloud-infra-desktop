# productivity/markdown.nix — terminal markdown renderers
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    mdcat
    glow
  ];
}
