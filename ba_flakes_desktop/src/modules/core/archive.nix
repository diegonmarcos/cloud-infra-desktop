# core/archive.nix — archive tools (zip/tar/rar formats)
# Phase 1a : zip + unzip + p7zip   (from profile-1)
# Phase 1f : + unrar               (from profile-7)
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    zip
    unzip
    p7zip
    unrar
  ];
}
