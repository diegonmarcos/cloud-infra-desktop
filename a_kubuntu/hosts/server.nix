# Server/VM minimal host configuration
{ config, pkgs, lib, ... }:

{
  # Minimal server packages
  home.packages = with pkgs; [
    # Monitoring
    htop
    btop
    iftop

    # Network diagnostics
    mtr
    tcpdump
  ];

  # Disable GUI-related programs
  programs.starship.settings.right_format = "";

  home.sessionVariables = {
    DEVICE = "server";
    PROFILE = "auth";
  };
}
