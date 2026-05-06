# Nix daemon settings, garbage collection, store optimization
{ config, pkgs, lib, ... }:

{
  # GC handled by storage-maintenance.service (daily at 4AM with btrfs balance)
  # Kept as fallback in case storage-maintenance is disabled
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # Keep max 5 system generations.
  # NOTE: bootloader has been yielded to aa_bootloader/ — generation pruning
  # for the actual menu lives in aa_bootloader/src/boot.json under
  # `grub.install.configuration_limit`. The two settings below are kept as
  # nix.gc-style hints (no-ops since both bootloader modules are disabled).
  boot.loader.systemd-boot.configurationLimit = 5;

  # ═══════════════════════════════════════════════════════════════════════════
  # NIX SETTINGS
  # ═══════════════════════════════════════════════════════════════════════════

  nix.settings = {
    max-jobs = "auto";
    cores = 0;
    substituters = [ "https://cache.nixos.org" ];
    trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
    keep-derivations = false;
    min-free = 1073741824;
    min-free-check-interval = 30;
    trusted-users = [ "root" "diego" ];

    # CRITICAL: Use btrfs-backed build directory, NOT tmpfs
    # Root (/) is a 2GB tmpfs (impermanence), /var/tmp lives there too.
    # Large builds (terraform go-modules, kernel) need 5-10GB temp space.
    # /nix is on btrfs with ~26GB free, so builds always have enough room.
    build-dir = "/nix/tmp";
  };
}
