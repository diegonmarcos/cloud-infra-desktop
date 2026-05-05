# media-graphics/images-edit.nix — raster + vector image editors
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    imagemagick
    gimp
    krita
    inkscape
  ];
}
