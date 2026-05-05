# productivity/spell.nix — aspell + dictionaries
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    aspell
    aspellDicts.en
    aspellDicts.es
  ];
}
