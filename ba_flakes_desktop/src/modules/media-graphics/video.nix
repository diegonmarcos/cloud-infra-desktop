# media-graphics/video.nix — video editors, players, transcoders
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    ffmpeg
    mpv
    vlc
    obs-studio
    kdePackages.kdenlive    # 25.05: top-level alias removed, use kdePackages
  ];
}
