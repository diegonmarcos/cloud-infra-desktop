# Swap + hibernation resume — extracted from hardware_filesystems.nix
# GENERATED FROM aa_bootloader/src/boot.json
# DO NOT EDIT BY HAND — re-generate via: aa_bootloader/build.sh deploy --target nixos
#
# POST-INCIDENT (2026-05-15): the consumer asserts the isolation invariant at
# build time. The 2026-05-15 pool destruction was caused by a btrfs swapfile
# whose CoW-relocatable extents overlapped live metadata chunks; hibernate
# wrote compressed RAM bytes into chunk 73 mirrors, destroying the FS. This
# module now refuses to build any config that re-introduces the dangerous
# coupling between resume target and pool.
#
# NOTE: `resume=` must be in boot.kernelParams explicitly. nixpkgs auto-injects
# `resume=${boot.resumeDevice}` only when boot.initrd.systemd.enable is true.
# This system uses the legacy initrd, so we set kernelParams explicitly.
{ config, lib, pkgs, ... }:

let
  bootCfg = builtins.fromJSON (builtins.readFile ./boot.json);
  sh = bootCfg.swap_hibernate;

  poolMountPrefixes = [ "/mnt/shared/" "/mnt/btrfs-root/" "/nix/" "/home/" ];
  swapfileOnPool = lib.any (p: lib.hasPrefix p sh.swapfile) poolMountPrefixes;
  resumeOnPool = sh.resume_device == "/dev/mapper/pool"
              || lib.hasPrefix "/dev/mapper/luks-" sh.resume_device;

  isolationOk = !swapfileOnPool && !resumeOnPool;
  paramsRendered = (sh.kernel_params or []) != []
                && lib.all (p: !(lib.hasInfix "@RESUME_OFFSET@" p)) (sh.kernel_params or []);
in
assert lib.assertMsg isolationOk ''
  swap_hibernate.swapfile = "${sh.swapfile}"
  swap_hibernate.resume_device = "${sh.resume_device}"
  Resume target or swapfile is on the btrfs pool. This is the EXACT configuration
  that caused the 2026-05-15 pool corruption. Refusing to build.
  Move swap to an ext4 partition and update boot.json.
  See: incident_2026-05-15_pool_hibernate_corruption.md
'';
assert lib.assertMsg paramsRendered ''
  swap_hibernate.kernel_params is empty or still contains the @RESUME_OFFSET@
  placeholder. Run `aa_bootloader/build.sh deploy --target nixos` to render
  resume_offset from the deployed swapfile via filefrag, then rebuild.
'';
{
  swapDevices = [{
    device = sh.swapfile;
    randomEncryption.enable = false;  # explicit: hibernate requires stable bytes
  }];

  boot.resumeDevice = sh.resume_device;
  boot.kernelParams = sh.kernel_params;
}
