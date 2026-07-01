# Containers: Podman, libvirt
#
# Docker daemon configuration is in docker-daemon.nix and its sub-modules.
{ config, pkgs, lib, ... }:
{
  # ═══════════════════════════════════════════════════════════════════════════
  # PODMAN + LIBVIRT (Data in @shared/data/containers/)
  # ═══════════════════════════════════════════════════════════════════════════

  virtualisation = {
    podman = {
      enable = true;
      dockerCompat = false;
      defaultNetwork.settings.dns_enabled = true;
    };

    libvirtd.enable = true;
  };

  virtualisation.containers.storage.settings = {
    storage = {
      driver = "btrfs";
      graphroot = "/mnt/shared/data/containers/podman";
    };
  };
  # Waydroid removed entirely 2026-07-01 (ghost Android procs survived GUI close).
}
