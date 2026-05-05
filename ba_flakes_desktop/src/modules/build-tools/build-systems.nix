# build-tools/build-systems.nix — meta-build / build-time tooling
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    cmake
    ninja
    gnumake
    meson
    automake
    autoconf
    libtool
    pkg-config
  ];
}
