# Swapfile resume-offset invariant gate (POST-INCIDENT 2026-05-15).
#
# WHY THIS EXISTS — historical context
# ────────────────────────────────────
# Original purpose: a btrfs swapfile's first physical block (4-KiB units, as
# reported by `btrfs inspect-internal map-swapfile -r`) drifts whenever btrfs
# balance/dedup runs or the swapfile is recreated/resized. systemd-logind's
# hibernate path then refuses with:
#   "Call to Hibernate failed: Specified resume device is missing or is not
#    an active swap device"
# This module used to silently SELF-HEAL by writing the actual offset to
# /sys/power/resume_offset and logging a warning that cmdline was stale.
#
# WHY THAT WAS WRONG — the 2026-05-15 incident
# ────────────────────────────────────────────
# Self-healing the /sys side made HIBERNATE ENTRY work, but the write target
# (the swapfile's current extents on btrfs) could overlap live metadata chunks
# because btrfs is free to place a NOCOW file anywhere in any data chunk. When
# hibernate fired, the compressed RAM image landed bytewise on top of chunk 73's
# DUP-mirrored metadata at physical 39.1/39.5 GB — two random-looking blobs
# (DUP mirrors should be identical; foreign overwrite proven by mirror divergence).
# Pool was unrecoverable. See incident_2026-05-15_pool_hibernate_corruption.md.
#
# WHAT THIS MODULE DOES NOW
# ─────────────────────────
# - The swapfile MUST live on an ext4 (or xfs) filesystem; mounting on btrfs is
#   refused.
# - The cmdline, /sys, and the swapfile's actual first physical extent MUST
#   agree. Any drift → mask systemd-hibernate.service this boot. No more silent
#   self-heal. Force user to redeploy boot.json + switch + reboot.
# - The bootloader-engine SoT is `~/git/unix/aa_bootloader/src/boot.json`
#   (`swap_hibernate.resume_offset`). Re-run `build.sh deploy --target nixos`
#   to repopulate from a fresh `filefrag -v -b4096 <swapfile>`.
{ config, pkgs, lib, ... }:

let
  bootCfg   = builtins.fromJSON (builtins.readFile ./boot.json);
  swapfile  = bootCfg.swap_hibernate.swapfile;
  declared  = toString bootCfg.swap_hibernate.resume_offset;
in
{
  systemd.services."swapfile-resume-offset-check" = {
    description = "Verify /sys/power/resume_offset matches the swapfile's actual first physical block (drift defeats hibernation)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "swap.target" "local-fs.target" ];
    before      = [ "sleep.target" "systemd-logind.service" ];
    serviceConfig = {
      Type           = "oneshot";
      RemainAfterExit = true;
      Slice          = "os-essentials.slice";
      OOMScoreAdjust = -900;
    };
    path = with pkgs; [ e2fsprogs coreutils util-linux systemd ];
    script = ''
      set -u
      SWAP="${swapfile}"
      DECLARED=${declared}

      mask_hibernate() {
        local reason="$1"
        ${pkgs.util-linux}/bin/logger -t swapfile-resume-offset -p user.crit \
          "REFUSED hibernate this boot: $reason"
        ${pkgs.systemd}/bin/systemctl mask --runtime systemd-hibernate.service \
                                                       systemd-hybrid-sleep.service \
                                                       hibernate.target \
                                                       hybrid-sleep.target 2>/dev/null || true
        exit 1
      }

      if [ ! -r "$SWAP" ]; then
        mask_hibernate "swapfile $SWAP not readable"
      fi

      # 1. The swapfile MUST live on ext4/xfs, NOT btrfs (incident 2026-05-15).
      SWAPFS=$(${pkgs.util-linux}/bin/findmnt -no FSTYPE -T "$SWAP" 2>/dev/null || echo unknown)
      case "$SWAPFS" in
        ext4|xfs) ;;
        btrfs)    mask_hibernate "swapfile is on btrfs ($SWAPFS) — see 2026-05-15 incident" ;;
        *)        mask_hibernate "swapfile is on unknown fs ($SWAPFS)" ;;
      esac

      # 2. Compute the swapfile's actual first physical block (4-KiB units).
      # filefrag -v -b4096 reports the first extent's physical_offset in 4-KiB units.
      ACTUAL=$(${pkgs.e2fsprogs}/bin/filefrag -v -b4096 "$SWAP" 2>/dev/null \
               | ${pkgs.gawk}/bin/awk '/^   0:/{print $4; exit}' | tr -d '.')
      if [ -z "$ACTUAL" ]; then
        mask_hibernate "filefrag could not determine first physical block of $SWAP"
      fi

      KERNEL=$(cat /sys/power/resume_offset 2>/dev/null || echo "?")
      CMDLINE=$(grep -o 'resume_offset=[0-9]*' /proc/cmdline | cut -d= -f2 || echo "?")

      echo "[swapfile-resume-offset] swapfile=$SWAP fs=$SWAPFS declared=$DECLARED kernel=/sys=$KERNEL cmdline=$CMDLINE actual=$ACTUAL"

      # 3. All three values MUST agree. No silent self-heal — drift means we
      #    don't know where hibernate will write OR where resume will read.
      if [ "$ACTUAL" != "$KERNEL" ]; then
        mask_hibernate "DRIFT (kernel-side): /sys/power/resume_offset=$KERNEL but swapfile actual=$ACTUAL"
      fi
      if [ "$ACTUAL" != "$CMDLINE" ]; then
        mask_hibernate "DRIFT (cmdline-side): cmdline resume_offset=$CMDLINE but swapfile actual=$ACTUAL — redeploy bootloader: cd ~/git/unix/aa_bootloader && ./build.sh deploy --target nixos && cd ../aa_desk-usr_x86_surface-linux_nixos && ./build.sh switch && reboot"
      fi
      if [ "$ACTUAL" != "$DECLARED" ]; then
        mask_hibernate "DRIFT (SoT-side): boot.json declared=$DECLARED but swapfile actual=$ACTUAL — redeploy bootloader to capture the new offset"
      fi

      echo "[swapfile-resume-offset] all invariants satisfied — hibernate enabled this boot"
    '';
  };
}
