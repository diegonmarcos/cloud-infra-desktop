# core/fonts.nix — programming fonts for terminals/IDEs
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    (nerdfonts.override { fonts = [ "JetBrainsMono" "FiraCode" ]; })
  ];
}
