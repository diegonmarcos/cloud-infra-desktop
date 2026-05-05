# media-graphics/viewers.nix — image / media viewers + color picker
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    feh
    imv
    gwenview
    kdePackages.kcolorchooser    # Color picker
    kdePackages.elisa            # Music player
    kdePackages.dragon           # Video player
  ];
}
