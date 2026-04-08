# Docker Daemon — orchestrator for modular daemon configuration
#
# Imports security, firewall, network, and resource sub-modules.
# Each sub-module contributes to virtualisation.docker.daemon.settings
# which NixOS merges and serializes to /etc/docker/daemon.json.
#
# Container runtime tools (Podman, Waydroid, libvirtd) remain in
# configuration_containers.nix — this module owns Docker daemon only.
{ config, pkgs, lib, ... }:

{
  imports = [
    ./docker-daemon-security.nix
    ./docker-daemon-firewall.nix
    ./docker-daemon-network.nix
    ./docker-daemon-resources.nix
  ];

  virtualisation.docker = {
    enable = true;
    storageDriver = "overlay2";
    autoPrune = {
      enable = true;
      dates = "daily";
      flags = [ "--all" "--filter" "until=24h" ];
    };
    daemon.settings = {
      data-root = "/mnt/kubuntu/docker";
    };
  };
}
