# security-net/network-analysis.nix — packet capture, scanning, traffic monitors
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    nmap
    netcat-openbsd
    mtr
    tcpdump
    wireshark-cli
    tshark
    iftop
    nethogs
  ];
}
