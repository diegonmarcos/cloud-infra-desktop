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
      # `label!=cloud.preserve=true` is load-bearing, not tidiness. This runs
      # `docker system prune -f --all --filter until=24h`, and prune removes every
      # STOPPED container plus (with --all) every image no RUNNING container uses.
      # Three settings in this very file conspire to make that fatal for long-lived
      # workloads: docker does not autostart (wantedBy = []), docker-no-restart forces
      # restart=no on everything, so at 00:00 nothing is running by definition — the
      # waydroid-container and its 4GB image were silently destroyed overnight
      # (observed 2026-09-01: `docker ps -a` and `docker images` both empty, 23G of
      # orphaned overlay2 left behind). Anything labelled cloud.preserve=true is now
      # exempt; the label is set in af_waydroid-container/src/Dockerfile and on
      # `docker run` in its build.sh.
      flags = [ "--all" "--filter" "until=24h" "--filter" "label!=cloud.preserve=true" ];
    };
    daemon.settings = {
      data-root = "/mnt/shared-lib/docker";
      live-restore = true;
    };
  };

  # Docker on-demand only — don't autostart, start manually with: systemctl start docker
  systemd.services.docker.wantedBy = lib.mkForce [];

  # Force all containers to restart=no — prevents buildkit etc from auto-starting
  # Runs once after docker starts, updates any container with a restart policy
  systemd.services.docker-no-restart = {
    description = "Set all Docker containers to restart=no";
    after = [ "docker.service" ];
    wantedBy = [ "docker.service" ];
    path = [ config.virtualisation.docker.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for cid in $(docker ps -aq 2>/dev/null); do
        docker update --restart=no "$cid" 2>/dev/null || true
      done
    '';
  };
}
