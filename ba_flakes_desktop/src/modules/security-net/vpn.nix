# security-net/vpn.nix — VPN clients
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    wireguard-tools
    openvpn
  ];
}
