# security-net/scanning.nix — security auditors
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    lynis
  ];
}
