# productivity/screenshots.nix — screenshot tools
# Decision (PLAN-module-split.md §8 #1): flameshot + maim live here, not in
# media-graphics/capture.nix.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    flameshot
    maim
  ];
}
