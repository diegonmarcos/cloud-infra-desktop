# media-graphics/audio.nix — audio editing + transcoding
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    audacity
    sox
    lame             # MP3 encoder
  ];
}
