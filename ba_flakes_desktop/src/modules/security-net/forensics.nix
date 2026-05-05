# security-net/forensics.nix — pattern matching, hex inspection, binary tooling
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    yara             # malware pattern matching (used by cloud-data-reports)
    binwalk
    hexyl
    xxd
    binutils         # includes strings, objdump, etc.
  ];
}
