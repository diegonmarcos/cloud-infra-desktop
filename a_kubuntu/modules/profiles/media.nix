# Media profile - Audio, video, and image processing
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # Image editing
    imagemagick
    gimp
    krita
    inkscape

    # Video
    ffmpeg
    mpv
    vlc
    obs-studio
    kdenlive

    # Audio
    audacity
    sox
    lame             # MP3 encoder

    # Screen capture
    flameshot
    peek             # GIF recorder
    simplescreenrecorder

    # Image viewing
    feh
    imv
    gwenview

    # Photo management
    digikam

    # Media info
    mediainfo
    exiftool

    # Drawing/Diagrams
    drawio

    # Color picker
    gpick
  ];
}
