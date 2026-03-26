# Docker Daemon — firewall policy
#
# Docker is FORBIDDEN from touching iptables/nftables.
# NixOS networking.firewall (configuration_network.nix) is the single owner
# of all packet filtering rules.
#
# Rules:
#   iptables    false — Docker creates zero iptables rules (no DNAT, no FORWARD, no NAT)
#   ip6tables   false — same for IPv6
#   ip-forward  false — kernel IP forwarding managed by NixOS, not Docker
#
# Consequence: automatic port publishing (docker run -p) will NOT work.
# This is intentional — on desktop, containers bind to localhost and are
# accessed directly or via a reverse proxy.
{ config, pkgs, lib, ... }:

{
  virtualisation.docker.daemon.settings = {
    iptables = false;
    ip6tables = false;
    ip-forward = false;
  };
}
