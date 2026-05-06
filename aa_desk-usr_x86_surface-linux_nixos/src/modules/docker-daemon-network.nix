# Docker Daemon — network topology
#
# Network is PERMISSIVE by default — all containers can communicate freely.
# Traffic restrictions are enforced externally by NixOS networking.firewall
# (configuration_network.nix), not by Docker daemon settings.
#
# Rules:
#   default-address-pools   Docker bridge networks use 172.16.0.0/12 range
#                           with /24 subnets per network. This avoids conflicts
#                           with WireGuard (10.0.0.0/24) and host networks.
{ config, pkgs, lib, ... }:

{
  virtualisation.docker.daemon.settings = {
    default-address-pools = [
      { base = "172.16.0.0/12"; size = 24; }
    ];
  };
}
