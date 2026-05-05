# core/network-basics.nix — fundamental network clients (HTTP, DNS, SSH, sync)
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    curl
    wget

    # File sync & transfer
    rsync
    rclone

    # DNS / general network basics
    bind             # dig, nslookup
    dnsutils
    inetutils        # telnet, ftp, etc.

    # SSH client
    openssh

    # Generic TCP/UDP plumbing
    socat
  ];
}
