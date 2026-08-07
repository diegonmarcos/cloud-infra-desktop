# /mnt/shared-lib (p5 ext4) corruption diagnostic — POST-2026-05-16.
#
# WHY THIS EXISTS
# ───────────────
# After the 2026-05-15 pool incident reinstall, /dev/nvme0n1p5 (ext4
# "Shared-Lib", holds the swapfile + src-code + recovered-home + docker
# data-root) gets corrupted on every NixOS boot cycle:
#
#   1. Kali fsck.ext4 → clean
#   2. Boot NixOS once
#   3. p5 superblock damaged (fsck reports group bitmap checksum errors
#      in groups 945-947 — at byte offset ~118 GiB, just PAST the 12 GiB
#      swap area which starts at 103.5 GiB).
#   4. Kali fsck → clean again
#   5. Boot NixOS → corrupted again. Reproducible.
#
# Hypothesis: hibernate writes overflow swap bounds. Groups 945-947 sit
# directly after the swapfile in physical layout, so a hibernate write
# off-by-one-extent or past-end-of-swap would land exactly there.
#
# WHAT THIS MODULE DOES
# ─────────────────────
# Capture every piece of evidence we can declaratively:
#
# 1. p5-fsck-preboot.service — runs fsck.ext4 -n (no fix, just check) on
#    p5 BEFORE local-fs.target. Logs result via journalctl CRIT. If the
#    previous boot corrupted p5, we see it NAMED at this boot's startup.
#
# 2. p5-snapshot.service — sha256s p5's superblock (first 4 KiB) + first
#    and last block-group descriptor table + GROUPS 945, 946, 947 bitmap
#    blocks. Writes to /var/log/p5-diag/<timestamp>.sha. Compared with
#    prior shutdown's snapshot to find WHAT EXACTLY changed.
#
# 3. p5-iostat.service — runs `iostat -dxm /dev/nvme0n1p5 5 60` for the
#    first 5 min of boot, logs to /var/log/p5-diag/iostat-<timestamp>.log.
#    Captures write spikes correlated with services starting.
#
# 4. p5-shutdown-snapshot.service — same as #2 but BEFORE umount.
#    Triggered by shutdown.target so we capture state right before reboot.
#
# 5. swap-trace.service — `dmesg --follow | grep -iE "hibern|resume|swap|
#    ext4-fs.*nvme0n1p5"` redirected to /var/log/p5-diag/dmesg.log.
#    Captures every kernel message about swap/hibernate/p5 with timestamps.
#
# ALL OUTPUT goes to:
#   - /var/log/p5-diag/  (persistent — /var/log is on @shared/log via
#                          configuration_persistence.nix)
#   - journalctl -t p5-diagnostic -p crit  (always captured)
{ config, lib, pkgs, ... }:

let
  p5Device = "/dev/disk/by-label/Shared-Lib";
  p5RawDevice = "/dev/nvme0n1p5";
  diagDir = "/var/log/p5-diag";

  # p5-fsck-preboot / p5-snapshot-boot: shell bodies live in
  # ./p5-fsck-preboot.sh and ./p5-snapshot-boot.sh, data-driven at runtime
  # from /etc/cloud-data/p5-diagnostic.json (declared below) instead of
  # Nix-interpolating the device paths / diag dir into the script bodies.
  p5FsckPreboot = pkgs.writeShellApplication {
    name = "p5-fsck-preboot";
    runtimeInputs = with pkgs; [ e2fsprogs util-linux coreutils jq ];
    text = builtins.readFile ./p5-fsck-preboot.sh;
  };
  p5SnapshotBoot = pkgs.writeShellApplication {
    name = "p5-snapshot-boot";
    runtimeInputs = with pkgs; [ coreutils util-linux gawk jq ];
    text = builtins.readFile ./p5-snapshot-boot.sh;
  };
in
{
  # Runtime data for p5-fsck-preboot / p5-snapshot-boot (new cloud-data path
  # — verified against the already-declared
  # environment.etc."cloud-data/..." set, no collisions).
  environment.etc."cloud-data/p5-diagnostic.json".text = builtins.toJSON {
    p5_device = p5Device;
    p5_raw_device = p5RawDevice;
    diag_dir = diagDir;
  };

  systemd.tmpfiles.rules = [
    "d ${diagDir} 0755 root root -"
  ];

  # ─── 1. fsck check BEFORE mount ─────────────────────────────────────
  systemd.services."p5-fsck-preboot" = {
    description = "Run fsck.ext4 -n on Shared-Lib BEFORE local-fs.target (corruption forensics)";
    wantedBy    = [ "local-fs.target" ];
    before      = [ "local-fs.target" "mnt-shared\\x2dlib.mount" ];
    # CRITICAL (2026-06-15): a service ordered Before=local-fs.target MUST set
    # DefaultDependencies=false. Without it, the implicit After=basic.target
    # (which is After=local-fs.target) forms an ordering cycle:
    #   local-fs.target → p5-fsck-preboot → basic.target → local-fs.target
    # systemd breaks cycles by DELETING jobs non-deterministically; on the
    # 2026-06-15 fresh-desktop boot it dropped NetworkManager's start job
    # (and broke audit.service), so NM never auto-started. DefaultDependencies
    # in [Unit] only — same class as the p5-snapshot-shutdown fix (2026-06-12).
    # The script already self-guards on device presence, so running early
    # (before the device settles) is safe — it just skips.
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type           = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError  = "journal+console";
      ExecStart      = "${p5FsckPreboot}/bin/p5-fsck-preboot";
    };
  };

  # ─── 2. Superblock + critical metadata snapshot at boot ─────────────
  systemd.services."p5-snapshot-boot" = {
    description = "Snapshot p5 superblock + groups 945-947 metadata at boot";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "mnt-shared\\x2dlib.mount" "p5-fsck-preboot.service" ];
    serviceConfig = {
      Type           = "oneshot";
      RemainAfterExit = true;
      ExecStart      = "${p5SnapshotBoot}/bin/p5-snapshot-boot";
    };
  };

  # ─── 3. iostat — first 5 min capture write spikes ─────────────────
  systemd.services."p5-iostat" = {
    description = "Capture p5 I/O for first 5 min of boot (write spike correlation)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "p5-snapshot-boot.service" ];
    serviceConfig = {
      Type           = "simple";
      Restart        = "no";
      Nice           = 19;
      IOSchedulingClass = "idle";
    };
    path = with pkgs; [ sysstat coreutils ];
    script = ''
      TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      LOG=${diagDir}/iostat-$TS.log
      mkdir -p ${diagDir}
      echo "[p5-iostat] capturing /dev/nvme0n1p5 I/O every 5s for 5 min" > $LOG
      # 60 iterations × 5s = 5 min
      iostat -dxm ${p5RawDevice} 5 60 >> $LOG 2>&1
      logger -t p5-diagnostic -p user.info "iostat capture complete: $LOG"
    '';
  };

  # ─── 4. Snapshot at shutdown ──────────────────────────────────────
  systemd.services."p5-snapshot-shutdown" = {
    description = "Snapshot p5 superblock + groups 945-947 BEFORE umount";
    wantedBy    = [ "shutdown.target" ];
    before      = [ "umount.target" "shutdown.target" ];
    # DefaultDependencies is a [Unit] key — in serviceConfig ([Service])
    # systemd ignores it with "Unknown key" and the implicit deps produce
    # sysinit.target/local-fs.target ordering cycles (seen on every boot of
    # the old generation).
    unitConfig = {
      DefaultDependencies = false;
    };
    serviceConfig = {
      Type           = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ coreutils util-linux gawk ];
    script = ''
      TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      SNAP=${diagDir}/snap-shutdown-$TS.sha
      mkdir -p ${diagDir}
      sync ${p5RawDevice} 2>/dev/null || true

      sb=$(dd if=${p5RawDevice} bs=4096 count=1 2>/dev/null | sha256sum | awk '{print $1}')
      echo "superblock(0..4KiB) $sb" > $SNAP
      for g in 945 946 947; do
        h=$(dd if=${p5RawDevice} bs=4096 count=32 skip=$((g * 32768)) 2>/dev/null | sha256sum | awk '{print $1}')
        echo "group_''${g}_first_128KiB $h" >> $SNAP
      done
      bsb=$(dd if=${p5RawDevice} bs=4096 count=1 skip=$((32 * 32768)) 2>/dev/null | sha256sum | awk '{print $1}')
      echo "backup_superblock_g32 $bsb" >> $SNAP

      logger -t p5-diagnostic -p user.info "shutdown snapshot written to $SNAP"
    '';
  };

  # ─── 5. dmesg follow — capture every swap/hibernate/p5 kernel msg ───
  systemd.services."p5-dmesg-trace" = {
    description = "Tail dmesg for swap/hibernate/p5 messages with timestamps";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "p5-snapshot-boot.service" ];
    serviceConfig = {
      Type           = "simple";
      Restart        = "always";
      RestartSec     = "10s";
    };
    path = with pkgs; [ util-linux gnugrep coreutils ];
    script = ''
      TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      LOG=${diagDir}/dmesg-$TS.log
      mkdir -p ${diagDir}
      echo "[p5-dmesg-trace] starting follow at $TS" > $LOG
      dmesg --follow --time-format=iso 2>&1 \
        | grep --line-buffered -iE "hibern|resume|swap|nvme0n1p5|ext4-fs.*p5|EXT4-fs error|swap_writepage|PM:" \
        >> $LOG
    '';
  };

  environment.systemPackages = with pkgs; [ e2fsprogs sysstat ];
}
