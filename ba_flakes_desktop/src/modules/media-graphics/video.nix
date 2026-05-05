# media-graphics/video.nix — video editors, players, transcoders
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    ffmpeg
    mpv
    vlc
    obs-studio
    kdenlive
  ];
}
