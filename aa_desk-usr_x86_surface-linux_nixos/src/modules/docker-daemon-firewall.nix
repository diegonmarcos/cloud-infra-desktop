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

  # Docker makes no NAT rules (above), so containers on the default docker0 bridge
  # have NO outbound internet. NixOS firewall is the single owner of NAT, so it
  # provides the masquerade here — outbound only (no inbound port publishing, so
  # the "containers bind localhost" posture is preserved). This is what gives the
  # redroid Android container (da_redroid, on docker0) WAN access.
  # externalInterface is the Wi-Fi NIC (primary WAN on this laptop); NAT applies
  # when routing out via it. internalInterfaces = docker0 covers every container
  # on the default bridge.
  networking.nat = {
    enable = true;
    externalInterface = "wlp0s20f3";
    internalInterfaces = [ "docker0" ];
  };
}
