#!/usr/bin/env bash
# swapfile-resume-offset-check.sh — verify /sys/power/resume_offset matches
# the swapfile's actual first physical block (drift defeats hibernation).
# See configuration_swapfile_resume_check.nix for the full incident history
# (POST-INCIDENT 2026-05-15) and unit wiring.
#
# Fully runtime-data-driven: swapfile path, declared resume_offset and
# resume_device are read at RUNTIME from BOOT_JSON
# (/etc/cloud-data/boot.json, key `.swap_hibernate`) via jq. Nothing is
# baked in by Nix interpolation. boot.json is already deployed to /etc by
# configuration_pre-hibernate-warning.nix (environment.etc) — this module
# reuses that same path rather than redeclaring it.
set -u

BOOT_JSON="${SWAPFILE_RESUME_BOOT_JSON:-/etc/cloud-data/boot.json}"

mask_hibernate() {
  local reason="$1"
  logger -t swapfile-resume-offset -p user.crit \
    "REFUSED hibernate this boot: $reason"
  systemctl mask --runtime systemd-hibernate.service \
                             systemd-hybrid-sleep.service \
                             hibernate.target \
                             hybrid-sleep.target 2>/dev/null || true
  exit 1
}

# This gate exists to REFUSE unsafe hibernation — if it cannot even read its
# own invariants, that is itself an unsafe-to-hibernate state. Fail loudly
# and refuse, same as every other mask_hibernate() path below.
if [ ! -r "$BOOT_JSON" ]; then
  mask_hibernate "config missing/unreadable at $BOOT_JSON"
fi
if ! jq -e . "$BOOT_JSON" >/dev/null 2>&1; then
  mask_hibernate "config unparseable at $BOOT_JSON"
fi

SWAP=$(jq -r '.swap_hibernate.swapfile // empty' "$BOOT_JSON")
DECLARED=$(jq -r '.swap_hibernate.resume_offset // empty' "$BOOT_JSON")
RESUME_DEV=$(jq -r '.swap_hibernate.resume_device // empty' "$BOOT_JSON")
if [ -z "$SWAP" ] || [ -z "$DECLARED" ] || [ -z "$RESUME_DEV" ]; then
  mask_hibernate "swap_hibernate.swapfile/resume_offset/resume_device missing from $BOOT_JSON"
fi

# Fresh-Desktop / rescue boots deliberately disable hibernation (noresume
# on cmdline, swapDevices=[], resumeDevice=""). The resume-offset
# invariants don't apply there, so SKIP cleanly instead of failing the
# unit — 2026-06-15: this exited 1 by design in fresh-desktop, leaving a
# failed unit + noise. grep-free cmdline test (coreutils only).
case " $(cat /proc/cmdline) " in
  *" noresume "*)
    echo "[swapfile-resume-offset] noresume on cmdline — hibernation disabled this boot; skipping resume-offset checks"
    logger -t swapfile-resume-offset -p user.info \
      "noresume boot (fresh-desktop/rescue) — resume-offset checks skipped"
    exit 0 ;;
esac

if [ ! -r "$SWAP" ]; then
  mask_hibernate "swapfile $SWAP not readable"
fi

# 1. The swapfile MUST live on ext4/xfs, NOT btrfs (incident 2026-05-15).
SWAPFS=$(findmnt -no FSTYPE -T "$SWAP" 2>/dev/null || echo unknown)
case "$SWAPFS" in
  ext4|xfs) ;;
  btrfs)    mask_hibernate "swapfile is on btrfs ($SWAPFS) — see 2026-05-15 incident" ;;
  *)        mask_hibernate "swapfile is on unknown fs ($SWAPFS)" ;;
esac

# 2. Compute the swapfile's actual first physical block (4-KiB units).
# filefrag -v -b4096 reports the first extent's physical_offset in 4-KiB units.
ACTUAL=$(filefrag -v -b4096 "$SWAP" 2>/dev/null \
         | awk '/^   0:/{print $4; exit}' | tr -d '.')
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
  mask_hibernate "DRIFT (cmdline-side): cmdline resume_offset=$CMDLINE but swapfile actual=$ACTUAL — redeploy bootloader: cd ~/git/cloud-infra-desktop/aa_bootloader && ./build.sh deploy --target nixos && cd ../aa_desk-usr_x86_surface-linux_nixos && ./build.sh switch && reboot"
fi
if [ "$ACTUAL" != "$DECLARED" ]; then
  mask_hibernate "DRIFT (SoT-side): boot.json declared=$DECLARED but swapfile actual=$ACTUAL — redeploy bootloader to capture the new offset"
fi

# 4. The declared resume_device MUST be the device backing the
#    swapfile's filesystem. If they diverge, hibernate would write the
#    image through the swapfile while resume reads resume= — i.e. two
#    different devices: the 2026-05-15 corruption class. Hard refuse.
RESOLVED=$(readlink -f "$RESUME_DEV" 2>/dev/null || echo "")
BACKING=$(findmnt -no SOURCE -T "$SWAP" 2>/dev/null || echo "")
if [ -z "$RESOLVED" ] || [ ! -b "$RESOLVED" ]; then
  mask_hibernate "resume_device $RESUME_DEV does not resolve to a block device"
fi
if [ "$RESOLVED" != "$BACKING" ]; then
  mask_hibernate "resume_device $RESUME_DEV → $RESOLVED but swapfile is backed by $BACKING — image and resume would target different devices"
fi

# 5. Register the resume device with the kernel if boot-time resolution
#    failed. The kernel only honors resume= if the device exists when
#    it parses the cmdline; if the partition appeared late (2026-06-12:
#    fslabel was destroyed, initrd gave up waiting), /sys/power/resume
#    stays 0:0 and systemd/logind reports CanHibernate=na — the battery
#    watchdog's hibernate calls then fail while the battery drains.
#    Writing the devno here is NOT the banned offset self-heal: steps
#    1-4 above already proved cmdline == /sys == actual extent AND the
#    device identity — this only completes the registration the kernel
#    would have done itself had the device been present at boot.
KRESUME=$(cat /sys/power/resume 2>/dev/null || echo "?")
DEVNO=$(stat -c '%Hr:%Lr' "$RESOLVED" 2>/dev/null || echo "?")
if [ "$KRESUME" = "0:0" ]; then
  echo "$DEVNO" > /sys/power/resume
  logger -t swapfile-resume-offset -p user.warning \
    "/sys/power/resume was 0:0 (resume device not present at boot) — registered $DEVNO ($RESOLVED) after invariant checks passed"
elif [ "$KRESUME" != "$DEVNO" ]; then
  mask_hibernate "/sys/power/resume=$KRESUME does not match resume_device $RESOLVED ($DEVNO)"
fi

echo "[swapfile-resume-offset] all invariants satisfied — hibernate enabled this boot"
