# media-graphics/viewers.nix — image / media viewers + color picker
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    feh
    imv
    kdePackages.gwenview         # 25.05: top-level alias removed, use kdePackages
    kdePackages.kcolorchooser    # Color picker
    kdePackages.elisa            # Music player
    kdePackages.dragon           # Video player
  ];
}
