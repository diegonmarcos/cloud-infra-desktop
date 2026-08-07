# System Protection — Storage Maintenance (daily)
#
# Runs daily at 4:00 AM:
#   1. Swap/cache cleanup (drop caches, trim zram)
#   2. Nix garbage collection (remove old generations)
#   3. Btrfs chunk consolidation (balance sparse data + metadata)
#   4. Btrfs scrub (monthly, integrity check)
#   5. Journal report with before/after chunk stats
#
# All output goes to journald → `journalctl -u storage-maintenance`
#
# ┌────────────────────────────┬──────────────────────────────────────────────┐
# │ Phase                      │ What it does                                │
# ├────────────────────────────┼──────────────────────────────────────────────┤
# │ 1. Cache/Swap cleanup      │ Drop dentries+inodes, sync, compact zram    │
# │ 2. Nix GC                  │ Delete generations >7d, optimize store links │
# │ 3. Btrfs balance           │ Consolidate data chunks <85% → free chunks  │
# │ 4. Btrfs balance (meta)    │ Consolidate metadata chunks <90%            │
# │ 5. Btrfs scrub             │ Monthly integrity check (1st of month)      │
# │ 6. Journal report          │ Before/after stats, chunk %, freed space    │
# └────────────────────────────┴──────────────────────────────────────────────┘
#
{ config, pkgs, lib, ... }:

let
  # Storage maintenance — script lives in storage-maintenance.sh (kept out of
  # the Nix module; inline scripts inside flake/nix modules are forbidden
  # here). It is fully DATA-DRIVEN: the btrfs mounts, atime windows, journal
  # vacuum settings, nix GC window, docker builder cache cap and btrfs
  # balance/scrub thresholds are all read at RUNTIME from
  # /etc/cloud-data/disk-protection.json (key `.storage_maintenance`) via
  # jq — nothing is baked in by Nix interpolation. That JSON is already
  # deployed by configuration_system-protection-disk.nix (environment.etc),
  # so this module reuses it rather than redeclaring the same /etc path.
  storageMaintenancePkg = pkgs.writeShellApplication {
    name = "storage-maintenance";
    text = builtins.readFile ./storage-maintenance.sh;
    runtimeInputs = with pkgs; [
      coreutils    # sync, free, date, du, stat, tr
      util-linux   # mountpoint, logger, fstrim
      btrfs-progs  # btrfs balance/scrub/filesystem usage
      nix          # nix-collect-garbage, nix-store --optimise
      systemd      # journalctl
      gawk         # chunk-stat parsing
      procps       # free
      findutils    # find
      jq           # runtime config parsing
    ];
  };
in
{
  # ═══════════════════════════════════════════════════════════════════════════
  # DAILY STORAGE MAINTENANCE TIMER
  # ═══════════════════════════════════════════════════════════════════════════

  systemd.timers."storage-maintenance" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      RandomizedDelaySec = "15min";
      Persistent = true;     # run on next boot if missed
    };
  };

  systemd.services."storage-maintenance" = {
    description = "Storage maintenance — cache/swap cleanup, nix GC, btrfs balance/scrub";
    serviceConfig = {
      Type = "oneshot";
      Nice = 19;
      IOSchedulingClass = "idle";
      TimeoutStartSec = "30min";
    };
    script = "${storageMaintenancePkg}/bin/storage-maintenance";
  };
}
