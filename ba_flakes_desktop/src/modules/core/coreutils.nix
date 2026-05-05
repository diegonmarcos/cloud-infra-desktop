# core/coreutils.nix — POSIX core utilities + general-purpose text/file tools
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    less
    bc
    file
    which
    diffutils
    patch
  ];
}
