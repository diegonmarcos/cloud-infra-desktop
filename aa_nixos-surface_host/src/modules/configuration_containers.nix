# Containers: Docker, Podman, libvirt, Waydroid
{ config, pkgs, lib, ... }:

{
  # ═══════════════════════════════════════════════════════════════════════════
  # WAYDROID (Android Container)
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # FIX: Don't auto-start container at boot to prevent GUI freezes.
  # The hwcomposer crash-loops every 5 seconds due to cgroup permission issues,
  # which creates resource contention that freezes KWin/Plasma.
  #
  # Start manually with: waydroid session start
  # Or select the "Android" session from SDDM login screen.
  #

  virtualisation.waydroid.enable = true;

  systemd.services.waydroid-container = {
    # Don't auto-start - only run when manually started
    wantedBy = lib.mkForce [];

    # When started, delegate cgroups properly to fix permission errors
    serviceConfig = {
      Delegate = "yes";
      KillMode = "mixed";
      TimeoutStopSec = 30;
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # CONTAINERS (Data in @shared/data/containers/)
  # ═══════════════════════════════════════════════════════════════════════════

  virtualisation = {
    docker = {
      enable = true;
      storageDriver = "btrfs";
      daemon.settings = {
        data-root = "/mnt/shared/data/containers/docker";
      };
    };

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
