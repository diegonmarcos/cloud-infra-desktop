# Kernel + initrd nix-store closure preserved on /boot (the ext4 boot volume).
#
# WHY THIS EXISTS (POST-INCIDENT 2026-05-15)
# ──────────────────────────────────────────
# During the 2026-05-15 incident reinstall, the previously-built
# linux-surface kernel (~30 min compile from source — cache.nixos.org and
# linux-surface.cachix.org both 404 on this exact derivation hash) was
# destroyed when @nixos was wiped. The recipe survives in the flake; the
# BINARY did not. Result: ~30 min of unnecessary kernel rebuild during the
# already-painful pool recovery.
#
# THE INVARIANT
# ─────────────
# /boot is the canonical home for everything kernel-related. Not just bzImage
# and initrd (rEFInd staging at /boot/kernels/) — the FULL nix-store closure
# for the kernel, initrd, and system toplevel. Surviving a pool wipe requires
# only that /boot itself survives, which is the user's stated invariant.
#
# WHAT IS PRESERVED
# ─────────────────
# - config.system.build.kernel           — /nix/store/<hash>-linux-X.Y/
#                                            (bzImage + vmlinux + lib/modules/
#                                             + include/ + System.map + ...)
# - config.system.build.initialRamdisk   — /nix/store/<hash>-initrd-linux-X.Y/
# - config.system.build.toplevel         — entire system closure (gated by
#                                            preserveFullSystem flag)
# Plus all their transitive runtime closures via `nix copy --to file://`.
#
# WHERE IT GOES
# ─────────────
# /boot/.nix-kernel-closure/ — a real Nix binary cache (narinfo + nar files,
# zstd-compressed). Mounted as part of /boot (ext4 p3). INCREMENTAL: each
# rebuild adds only new paths, never duplicates.
#
# CAPACITY / "NEVER FILL"
# ───────────────────────
# /boot at install time is 2 GiB. That fits 1–2 kernel generations comfortably,
# but the user wants /boot to NEVER fill. Plan:
#
#   Phase 1 (this module, active now): retention policy auto-prunes the
#     closure cache to the most recent `maxGenerations` (default: 3) kernel +
#     initrd store paths. Pre-write check refuses to copy when /boot would
#     drop below `minFreeMiB` (default: 256). On write-refused, logs CRIT to
#     journal so the user knows.
#
#   Phase 2 (one-time offline op, post-install): physically grow /boot from
#     2 GiB → 32 GiB by shrinking /mnt/shared-lib (p5, 118 GiB, ~80 GiB free).
#     Requires offline parted surgery from a rescue OS. After that, retention
#     can be loosened (keep more generations). See:
#       aa_bootloader/src/boot.json — partitions slice (post-2026-05-15 grow)
#
# RECOVERY (from rescue OS / live USB)
# ────────────────────────────────────
#   sudo kernel-closure-restore /mnt/nixos/nix
# (system-wide CLI; reads from /boot/.nix-kernel-closure, writes into a
# target nix store. Default target is /mnt/nixos/nix — the standard reinstall
# mount point.)
{ config, pkgs, lib, ... }:

let
  cache       = "/boot/.nix-kernel-closure";
  # Keep at most this many kernel+initrd derivations in the cache.
  # Generations beyond this get nix-store --delete'd from the cache.
  maxGenerations  = 3;
  # Refuse to write if /boot would drop below this many MiB free.
  minFreeMiB      = 256;
  # Preserve the entire system toplevel (true) vs just kernel+initrd (false).
  # Until /boot is grown (Phase 2), set this to FALSE so we don't blow out
  # the 2 GiB partition. Re-enable AFTER the partition grow.
  preserveFullSystem = false;

  preservedPaths =
    [ config.system.build.kernel
      config.system.build.initialRamdisk
    ]
    ++ lib.optional preserveFullSystem config.system.build.toplevel;

  # Recovery CLI — reads from the on-/boot cache, writes into a target store.
  # Shell body lives in ./kernel-closure-restore.sh; runtime config comes
  # from /etc/cloud-data/kernel-closure-preservation.json (declared below).
  kernelClosureRestore = pkgs.writeShellApplication {
    name = "kernel-closure-restore";
    runtimeInputs = with pkgs; [ nix coreutils util-linux jq ];
    text = builtins.readFile ./kernel-closure-restore.sh;
  };

  # Manual on-demand backup (idempotent — same as the systemd unit's logic).
  # Shell body lives in ./kernel-closure-backup.sh, data-driven at runtime
  # from the same JSON.
  kernelClosureBackup = pkgs.writeShellApplication {
    name = "kernel-closure-backup";
    runtimeInputs = with pkgs; [ nix coreutils util-linux findutils jq ];
    text = builtins.readFile ./kernel-closure-backup.sh;
  };

  # Retention pruner — drops narinfo files for kernel/initrd store paths
  # older than the most-recent maxGenerations. Run by a timer + after backup.
  # Shell body lives in ./kernel-closure-prune.sh, data-driven at runtime
  # from the same JSON.
  kernelClosurePrune = pkgs.writeShellApplication {
    name = "kernel-closure-prune";
    runtimeInputs = with pkgs; [ coreutils findutils gnugrep nix jq util-linux ];
    text = builtins.readFile ./kernel-closure-prune.sh;
  };

in
{
  # Runtime data for kernel-closure-restore/backup/prune (new cloud-data
  # path — verified against the already-declared
  # environment.etc."cloud-data/..." set, no collisions). preserved_paths is
  # evaluation-time data (the actual kernel/initrd/toplevel store paths for
  # THIS system generation), not a user-tunable knob, so it's generated here
  # via toJSON rather than hand-authored — but still read at runtime via jq
  # like every other field, never Nix-interpolated into the .sh bodies.
  environment.etc."cloud-data/kernel-closure-preservation.json".text =
    builtins.toJSON {
      inherit cache;
      min_free_mib = minFreeMiB;
      max_generations = maxGenerations;
      preserved_paths = map (p: "${p}") preservedPaths;
    };

  # ── /boot/.nix-kernel-closure as a PERMANENT Nix substituter ─────────────
  # This is the "kernel-specific nix-store" pattern (per user spec
  # 2026-05-16): make the on-/boot binary cache a first-class Nix
  # substituter so EVERY nix build / nixos-rebuild / fresh install
  # transparently consults /boot before building anything. No manual
  # `kernel-closure-restore` needed in the normal case — Nix finds the
  # kernel there automatically.
  #
  # Priority 5 = checked BEFORE cache.nixos.org (default priority 40).
  # Trusted = bypass signature checks (we write with --no-check-sigs).
  nix.settings = {
    extra-substituters = [ "file:///boot/.nix-kernel-closure?priority=5" ];
    extra-trusted-substituters = [ "file:///boot/.nix-kernel-closure" ];
  };

  # Ensure cache dir exists with right perms at boot.
  systemd.tmpfiles.rules = [
    "d /boot/.nix-kernel-closure 0755 root root -"
  ];

  # ── 1. On every activation, mirror the current kernel+initrd closure ────
  # to /boot/.nix-kernel-closure. Incremental (nix copy skips existing
  # paths). Refuses to write if /boot would drop below minFreeMiB.
  systemd.services."kernel-closure-preservation" = {
    description = "Mirror current kernel + initrd closure to /boot/.nix-kernel-closure";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "boot.mount" "local-fs.target" "multi-user.target" ];
    requires    = [ "boot.mount" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      Nice            = 10;
      IOSchedulingClass = "idle";
      ExecStart       = "${kernelClosureBackup}/bin/kernel-closure-backup";
      ExecStartPost   = "${kernelClosurePrune}/bin/kernel-closure-prune";
    };
  };

  # ── 2. Weekly prune (catches generations from frequent rebuilds) ────────
  systemd.timers."kernel-closure-prune" = {
    description = "Weekly prune of /boot/.nix-kernel-closure to maxGenerations";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnCalendar     = "weekly";
      Persistent     = true;
      RandomizedDelaySec = "1h";
    };
  };
  systemd.services."kernel-closure-prune" = {
    description = "Prune /boot/.nix-kernel-closure to last ${toString maxGenerations} generations";
    serviceConfig = {
      Type      = "oneshot";
      ExecStart = "${kernelClosurePrune}/bin/kernel-closure-prune";
    };
  };

  environment.systemPackages = [
    kernelClosureRestore   # `kernel-closure-restore [/mnt/nixos/nix]`
    kernelClosureBackup    # `kernel-closure-backup`  (manual)
    kernelClosurePrune     # `kernel-closure-prune`   (manual / via timer)
  ];
}
