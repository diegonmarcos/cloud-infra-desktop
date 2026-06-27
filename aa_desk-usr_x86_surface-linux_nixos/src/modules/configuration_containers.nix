# Containers: Podman, libvirt
#
# Docker daemon configuration is in docker-daemon.nix and its sub-modules.
# Waydroid removed from systemd — it is a user-launched app, not a system service.
# Run manually: waydroid session start && waydroid show-full-ui
{ config, pkgs, lib, nurpkgs, ... }:
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
}
