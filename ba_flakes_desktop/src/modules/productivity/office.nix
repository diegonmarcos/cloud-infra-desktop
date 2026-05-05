# productivity/office.nix — office suite (LibreOffice ~1.4 GB)
# Heaviest single home-manager package. Toggleable on its own per host.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    libreoffice
  ];
}
