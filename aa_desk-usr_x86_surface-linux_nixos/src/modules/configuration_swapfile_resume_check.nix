# Swapfile resume-offset drift detector + self-healer.
#
# WHY THIS EXISTS
# ───────────────
# Hibernation on a btrfs swapfile needs three things to agree:
#   1. /proc/cmdline `resume=<dev>` matches the FS the swapfile lives on
#   2. /proc/cmdline `resume_offset=<N>` matches the swapfile's first physical
#      block (4-KiB units), as reported by:
#        btrfs inspect-internal map-swapfile -r <swapfile>
#   3. The swapfile is registered in /proc/swaps
#
# When btrfs balance/dedup runs, or the swapfile is recreated/resized, (2)
# drifts. systemd-logind's hibernate path then refuses with:
#   "Call to Hibernate failed: Specified resume device is missing or is not
#    an active swap device"
# — and even though the battery-watchdog correctly fires `systemctl hibernate`,
# nothing happens. This is exactly what killed the laptop on 2026-05-06 at 01:22:
# the watchdog tripped 22 times between 01:00–01:21, every attempt rejected,
# and the firmware power-cut at 0%.
#
# This module:
#   - Runs at boot after swap.target, before sleep.target
#   - Computes the canonical offset via `btrfs inspect-internal map-swapfile -r`
#   - Compares to /sys/power/resume_offset (which kernel set from cmdline)
#   - If mismatch: writes the correct value to /sys/power/resume_offset so
#     ENTERING hibernation works for the current session, and logs a loud
#     WARNING that the cmdline still has the stale value so RESUME (next
#     boot's image-recovery) won't find the image — user must run the
#     bootloader engine + switch + reboot to fully fix.
#
# The bootloader-engine SoT is `~/git/unix/aa_bootloader/src/boot.json`
# (`swap_hibernate.resume_offset`). Update + redeploy + switch + reboot is
# the canonical way to drift-correct.
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
    path = with pkgs; [ btrfs-progs coreutils util-linux systemd ];
    script = ''
      set -u
      SWAP="${swapfile}"
      DECLARED=${declared}

      if [ ! -r "$SWAP" ]; then
        echo "[swapfile-resume-offset] $SWAP not readable — skipping"
        exit 0
      fi

      # Authoritative offset for resume_offset= kernel param.
      ACTUAL=$(${pkgs.btrfs-progs}/bin/btrfs inspect-internal map-swapfile -r "$SWAP" 2>/dev/null || echo "")
      if [ -z "$ACTUAL" ]; then
        echo "[swapfile-resume-offset] map-swapfile failed — leaving /sys/power/resume_offset as-is"
        exit 0
      fi

      KERNEL=$(cat /sys/power/resume_offset 2>/dev/null || echo "?")
      CMDLINE=$(grep -o 'resume_offset=[0-9]*' /proc/cmdline | cut -d= -f2 || echo "?")

      echo "[swapfile-resume-offset] swapfile=$SWAP declared=$DECLARED kernel=/sys=$KERNEL cmdline=$CMDLINE actual=$ACTUAL"

      if [ "$ACTUAL" = "$KERNEL" ]; then
        echo "[swapfile-resume-offset] ok — kernel runtime matches actual"
        # Still warn if cmdline (used at resume time) differs.
        if [ "$ACTUAL" != "$CMDLINE" ]; then
          ${pkgs.util-linux}/bin/logger -t swapfile-resume-offset -p user.warning \
            "cmdline resume_offset=$CMDLINE differs from actual=$ACTUAL — RESUME (post-hibernate boot) will fail. Run: cd ~/git/unix/aa_bootloader && YES=1 ./build.sh deploy --target nixos && cd ../aa_nixos-surface_host && ./build.sh switch && reboot"
        fi
        exit 0
      fi

      # Self-heal: ENTERING hibernation needs /sys/power/resume_offset to match
      # the swapfile, otherwise systemd-logind refuses. We can fix that here
      # without a reboot.
      echo "[swapfile-resume-offset] DRIFT detected: kernel=$KERNEL actual=$ACTUAL — writing $ACTUAL to /sys/power/resume_offset"
      if echo "$ACTUAL" > /sys/power/resume_offset 2>/dev/null; then
        ${pkgs.util-linux}/bin/logger -t swapfile-resume-offset -p user.warning \
          "Auto-corrected /sys/power/resume_offset $KERNEL→$ACTUAL. Hibernation ENTRY now works for this boot. Cmdline still has $CMDLINE — RESUME after hibernate will fail until: cd ~/git/unix/aa_bootloader && YES=1 ./build.sh deploy --target nixos && cd ../aa_nixos-surface_host && ./build.sh switch && reboot"
        echo "[swapfile-resume-offset] /sys/power/resume_offset is now $(cat /sys/power/resume_offset)"
      else
        ${pkgs.util-linux}/bin/logger -t swapfile-resume-offset -p user.err \
          "Failed to write $ACTUAL to /sys/power/resume_offset (errno=$?) — hibernation will fail at ENTRY"
        echo "[swapfile-resume-offset] WRITE FAILED — hibernation will fail until reboot+switch"
        exit 1
      fi
    '';
  };
}
