# media-graphics/design.nix — diagramming + color tools
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    drawio
    gpick            # Color picker
  ];
}
