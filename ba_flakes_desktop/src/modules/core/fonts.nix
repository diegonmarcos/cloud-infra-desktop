# core/fonts.nix — programming fonts for terminals/IDEs
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    # 25.05: nerdfonts split into the nerd-fonts.* namespace (per-font packages)
    nerd-fonts.jetbrains-mono
    nerd-fonts.fira-code
  ];
}
