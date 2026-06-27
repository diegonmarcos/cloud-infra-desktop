# Containers: Podman, libvirt, Waydroid
#
# Docker daemon configuration is in docker-daemon.nix and its sub-modules.
# Waydroid: unit exists for on-demand launch (via waydroid-launch desktop entry)
# but does NOT auto-start at boot (wantedBy forced empty).
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

  # ═══════════════════════════════════════════════════════════════════════════
  # WAYDROID — on-demand only, NOT a boot service
  # ═══════════════════════════════════════════════════════════════════════════
  # Enable = true so the unit file exists (waydroid-launch script calls
  # `systemctl start/stop waydroid-container`). Force wantedBy empty so it
  # never auto-starts at boot. The launcher desktop entry handles lifecycle.
  virtualisation.waydroid.enable = true;
  systemd.services.waydroid-container.wantedBy = lib.mkForce [];
}
