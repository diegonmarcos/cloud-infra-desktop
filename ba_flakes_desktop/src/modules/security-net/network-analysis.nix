# security-net/network-analysis.nix — packet capture, scanning, traffic monitors
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    nmap
    netcat-openbsd
    mtr
    whois            # ASN / org lookups — used by ~/triage.sh WHOIS section
    tcpdump
    wireshark-cli
    tshark
    iftop
    nethogs
  ];
}
