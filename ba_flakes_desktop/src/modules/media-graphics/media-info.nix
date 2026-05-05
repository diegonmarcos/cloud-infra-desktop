# media-graphics/media-info.nix — metadata inspectors
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    mediainfo
    exiftool
  ];
}
