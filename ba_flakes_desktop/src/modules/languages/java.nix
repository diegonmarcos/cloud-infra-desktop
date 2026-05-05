# languages/java.nix — JDK
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    jdk
  ];
}
