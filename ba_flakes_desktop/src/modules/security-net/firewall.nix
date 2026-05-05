# security-net/firewall.nix — userland firewall CLI tools
# System-level firewall rules belong to NixOS, not home-manager — this leaf
# only carries the iptables/nftables CLIs themselves.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    iptables
    nftables
  ];
}
