#!/usr/bin/env bash
# hibernate-preflight.sh — pre-flight correctness gate for every hibernation
# path (POST-INCIDENT 2026-05-15). See configuration_pre-hibernate-warning.nix
# for the ExecStartPre= wiring on systemd-hibernate.service and the full
# incident history.
#
# Fully runtime-data-driven: the swapfile path and resume device are read at
# RUNTIME from BOOT_JSON (/etc/cloud-data/boot.json, the
# aa_bootloader/src/boot.json SoT for swap/resume invariants) via jq. Nothing
# is baked in by Nix interpolation.
set -u

BOOT_JSON="${HIBERNATE_BOOT_JSON:-/etc/cloud-data/boot.json}"

# This gate exists to REFUSE unsafe hibernation — if it cannot even read its
# own invariants, that is itself an unsafe-to-hibernate state. Fail loudly
# and refuse, same as every other die() path below.
if [ ! -r "$BOOT_JSON" ]; then
  logger -t hibernate-preflight -p user.crit "hibernate-preflight: BOOT_JSON MISSING/UNREADABLE at $BOOT_JSON — refusing to hibernate with no verified invariants"
  echo "REFUSED hibernate: config missing/unreadable at $BOOT_JSON" >&2
  exit 1
fi
if ! jq -e . "$BOOT_JSON" >/dev/null 2>&1; then
  logger -t hibernate-preflight -p user.crit "hibernate-preflight: BOOT_JSON UNPARSEABLE at $BOOT_JSON — refusing to hibernate with no verified invariants"
  echo "REFUSED hibernate: config unparseable at $BOOT_JSON" >&2
  exit 1
fi

SWAP=$(jq -r '.swap_hibernate.swapfile // empty' "$BOOT_JSON")
RESUME=$(jq -r '.swap_hibernate.resume_device // empty' "$BOOT_JSON")
if [ -z "$SWAP" ] || [ -z "$RESUME" ]; then
  logger -t hibernate-preflight -p user.crit "hibernate-preflight: swap_hibernate.swapfile/resume_device missing from $BOOT_JSON — refusing to hibernate"
  echo "REFUSED hibernate: swap_hibernate.swapfile/resume_device missing from $BOOT_JSON" >&2
  exit 1
fi

die() {
  local msg="REFUSED hibernate: $1"
  logger -t hibernate-preflight -p user.crit "$msg"
  echo "$msg" | wall -n 2>/dev/null || true
  for udir in /run/user/*; do
    [ -d "$udir" ] || continue
    uid=$(basename "$udir")
    user=$(awk -F: -v u="$uid" '$3==u{print $1; exit}' /etc/passwd) || continue
    [ -n "$user" ] || continue
    bus="$udir/bus"
    [ -S "$bus" ] || continue
    runuser -u "$user" -- env \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" XDG_RUNTIME_DIR="$udir" \
      notify-send -u critical -a Power \
        "Hibernation REFUSED" "$1" 2>/dev/null || true
  done
  exit 1
}

# 1. Swapfile is on ext4 (or xfs) — never on btrfs (see 2026-05-15 incident).
SWAPFS=$(findmnt -no FSTYPE -T "$SWAP" 2>/dev/null) \
  || die "swapfile $SWAP not on any mounted FS"
case "$SWAPFS" in
  ext4|xfs) ;;
  btrfs)    die "swapfile is on btrfs — see incident 2026-05-15" ;;
  *)        die "swapfile is on unsupported fs ($SWAPFS)" ;;
esac

# 2. resume_device is reachable and is NOT the pool.
case "$RESUME" in
  /dev/mapper/pool|/dev/mapper/luks-*)
    die "resume_device $RESUME is on the btrfs pool (forbidden post-2026-05-15)" ;;
esac
RESOLVED=$(readlink -f "$RESUME" 2>/dev/null) \
  || die "resume device $RESUME does not resolve"
[ -b "$RESOLVED" ] || die "resume device $RESUME ($RESOLVED) is not a block device"

# 3. swsusp signature in the SWAP HEADER is SWAPSPACE2 (no stale image).
#    The swap header lives in the FIRST PAGE OF THE SWAPFILE — the 10-byte
#    magic sits at offset (pagesize-10)=4086. It is NOT at offset 0 of the
#    backing device: that is the ext4 superblock. Reading $RESOLVED here
#    was the 2026-06-13 regression that refused EVERY hibernation (same
#    device-vs-swapfile confusion class as the 2026-06-12 p5 incident).
#    SWAPSPACE2 = clean swap, no pending image. S1SUSPEND = image present.
SIG=$(dd if="$SWAP" bs=1 skip=4086 count=10 2>/dev/null)
case "$SIG" in
  SWAPSPACE2) ;;
  S1SUSPEND*) die "stale hibernate signature (S1SUSPEND) in $SWAP — refusing to overwrite. Run: sudo swapoff $SWAP && sudo mkswap $SWAP && sudo swapon $SWAP" ;;
  *)          die "no valid swap signature in $SWAP header (got '$SIG') — run: sudo mkswap $SWAP" ;;
esac

# 4. Pool-witness check: if the pool was mounted by something other than
#    NixOS since last clean unmount, RAM-state-of-pool is stale.
WITNESS_DISK=/mnt/shared/.pool-witness/id
WITNESS_RUN=/run/pool-witness/current-mount.id
if [ -r "$WITNESS_RUN" ]; then
  CUR=$(cat "$WITNESS_RUN")
  DISK=$(cat "$WITNESS_DISK" 2>/dev/null || echo "")
  if [ -n "$DISK" ] && [ "$CUR" != "$DISK" ]; then
    die "pool witness mismatch (runtime=$CUR disk=$DISK) — pool was modified out-of-band this session"
  fi
fi

logger -t hibernate-preflight -p user.info \
  "preflight ok (swapfs=$SWAPFS, resume=$RESUME, header=SWAPSPACE2)"
