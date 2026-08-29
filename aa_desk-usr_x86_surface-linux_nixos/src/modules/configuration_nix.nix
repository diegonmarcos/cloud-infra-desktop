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
  # NIX SETTINGS  (canonical block — substituters + trusted-public-keys live HERE)
  # ═══════════════════════════════════════════════════════════════════════════
  # U2 (PLAN-resource-bouncer.md / PLAN-hardening §1C): the old monolithic
  # aa_desk-usr_x86_surface-linux_nixos/src/configuration.nix had TWO `nix.settings = { … }`
  # blocks in ONE attribute set, where the second silently shadowed the first's
  # substituters/trusted-public-keys (the reported data loss). The 77-leaf split
  # dissolved that: nix.settings is now owned by exactly TWO modules that use
  # DISJOINT keys, so NixOS module merge is purely ADDITIVE and nothing is lost:
  #   • configuration_nix.nix (here)               → substituters, trusted-public-keys
  #   • configuration_kernel_preservation.nix:188  → extra-substituters, extra-trusted-substituters
  # INVARIANT: keep substituters/trusted-public-keys ONLY in this file. Do NOT
  # add a second `substituters`/`trusted-public-keys` in any other module — that
  # would reintroduce the shadow. `extra-*` keys elsewhere are safe (additive).

  # Builds must NEVER starve the interactive session (2026-06-12: parallel
  # rebuild storm + kswapd IO-trashed the desktop on this 8-core/8GB machine).
  # idle-class CPU + IO scheduling makes every nix-daemon build yield to any
  # interactive load while still using free cycles at full speed.
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass   = "idle";

  nix.settings = {
    # 1 derivation × 4 threads max (8 cores: half stays interactive even at
    # full build load; build.sh passes the same caps explicitly per run).
    max-jobs = 1;
    cores = 4;
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
