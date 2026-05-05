# security-net/passwords-gui.nix — password manager GUI
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    bitwarden-desktop  # Vaultwarden/Bitwarden GUI client
  ];
}
