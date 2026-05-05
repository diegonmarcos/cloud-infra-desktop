# media-graphics/capture.nix — screen recording (NOT screenshot — see
# productivity/screenshots.nix for flameshot/maim, per PLAN §8 #1).
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    peek                  # GIF recorder
    simplescreenrecorder
  ];
}
