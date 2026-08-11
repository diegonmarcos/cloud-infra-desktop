#!/usr/bin/env bash
# migrate-nosnap-subvols.sh — move regenerable caches into @nosnap/* subvolumes.
#
# Pairs with hardware_filesystems_nosnap.nix. That module DECLARES the mounts;
# configuration_btrfs_subvols_autocreate.nix will not create a subvol for a path
# that is a plain dir WITH DATA (it logs CRIT and skips, by design — activation
# must never move user data implicitly). This script is that deliberate step.
#
# WHY reflink AND WHY THAT MAKES IT SPACE-NEUTRAL
# ───────────────────────────────────────────────
# A plain `mv` across subvolumes is a FULL COPY — 24G for ~/git alone, on a pool
# with ~5G free. `cp --reflink` shares extents instead of duplicating them, so
# the copy is near-instant and costs ~nothing until the two diverge. Same
# filesystem is required; every path here is on /dev/mapper/pool, so it holds.
#
# ORDER MATTERS
# ─────────────
# Delete the pinning session-checkpoint snapshots BEFORE running this. While a
# snapshot references the old extents nothing is reclaimed, and the renamed
# .premigration copies stay on disk in full.
#
#   sudo btrfs subvolume delete /mnt/btrfs-root/@snapshots/home-diego/<stamp>
#
# WHAT THIS DOES NOT DO
# ─────────────────────
# It never deletes your data. Originals are renamed <path>.premigration and left
# for you to remove once the new mounts are verified.
#
# It also never leaves a path empty. Each subvol is mounted with an explicit
# -o subvol=... the moment its contents are copied, NOT at the next reboot:
# between the rename and the mount the path is an empty directory, and for
# /home/diego/git that would mean every repo on the machine disappearing from
# where every tool expects it. If that mount fails the original is moved back
# and the script aborts. An explicit mount needs no fstab entry, so this works
# whether or not hardware_filesystems_nosnap.nix has been switched in yet —
# the switch only matters for making the mounts survive a reboot.
#
# Usage:  sudo ./migrate-nosnap-subvols.sh --apply
#         (no --apply = dry run, prints the plan and exits)
set -euo pipefail

BTRFS_ROOT=/mnt/btrfs-root
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

# Keep in sync with hardware_filesystems_nosnap.nix `nosnap`.
# path<TAB>subvol
ENTRIES="
/home/diego/git	@nosnap/git
/home/diego/.local/share/octocode	@nosnap/octocode
/home/diego/.local/share/claude	@nosnap/claude
/home/diego/.local/share/antigravity-ide	@nosnap/antigravity-ide
/home/diego/.cache	@nosnap/cache
/home/diego/.cargo	@nosnap/cargo
/home/diego/.gradle	@nosnap/gradle
/home/diego/.node_modules	@nosnap/node_modules
"

log()  { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

# Root is only needed to WRITE. Gating the dry run on it too would mean you
# could not read the plan without sudo, which is exactly backwards for a script
# whose whole point is being inspected before it touches 24G of data.
if [ "$APPLY" -eq 1 ]; then
  [ "$(id -u)" -eq 0 ] || die "must run as root (btrfs subvolume create)"
  mountpoint -q "$BTRFS_ROOT" || die "$BTRFS_ROOT not mounted — cannot create subvolumes"
fi

# Refuse to run while a checkpoint snapshot still pins the old extents: the
# migration would appear to succeed while freeing nothing, which is exactly the
# confusion this whole change exists to end.
# `|| true` is load-bearing: with `set -o pipefail`, find exiting non-zero
# (the snapshot dir is absent once every snapshot has been deleted — the normal
# state after a cleanup) propagates through the pipe and `set -e` kills the
# script before it prints anything at all. Absent dir means zero snapshots,
# which is the good case, not an error.
SNAPS=$( { find "$BTRFS_ROOT/@snapshots/home-diego" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true; } | wc -l)
if [ "$SNAPS" -gt 0 ]; then
  warn "$SNAPS session-checkpoint snapshot(s) still present — they pin the old extents."
  warn "Nothing will actually be reclaimed until they are deleted:"
  find "$BTRFS_ROOT/@snapshots/home-diego" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's/^/    /'
  [ "$APPLY" -eq 1 ] && warn "Continuing anyway — migration itself is still correct."
fi

[ "$APPLY" -eq 1 ] || log "DRY RUN — pass --apply to execute"

# Here-string, NOT `printf | while`: a pipeline puts the loop in a subshell, so
# `set -e` firing inside it kills the listing silently — which it did, via the
# `du` below returning non-zero on an unreadable subdir and taking the whole
# plan output with it.
while IFS=$'\t' read -r SRC SUBVOL; do
  [ -n "${SRC:-}" ] || continue
  DEST="$BTRFS_ROOT/$SUBVOL"

  if btrfs subvolume show "$DEST" >/dev/null 2>&1; then
    log "SKIP $SUBVOL — subvolume already exists"
    continue
  fi
  if [ ! -d "$SRC" ]; then
    log "SKIP $SRC — not present (subvol will be autocreated empty on activation)"
    continue
  fi

  # `|| true`: du exits non-zero on any unreadable subdir, and a bare assignment
  # from a failed substitution is fatal under `set -e`. The size is cosmetic —
  # it must never be able to abort the migration.
  SZ=$(du -sh "$SRC" 2>/dev/null | cut -f1 || true)
  log "MIGRATE $SRC (${SZ:-?}) → $SUBVOL"
  [ "$APPLY" -eq 1 ] || continue

  mkdir -p "$(dirname "$DEST")"
  btrfs subvolume create "$DEST" >/dev/null || die "failed creating $DEST"
  # --reflink=auto, not =always: falls back to a real copy rather than failing
  # outright if a path ever lands on a different filesystem.
  cp -a --reflink=auto "$SRC/." "$DEST/" || die "copy failed for $SRC"

  # Verify by entry count before touching the original. Cheap, and catches a
  # truncated copy; a byte-exact compare over 24G is not worth the wall time.
  N_SRC=$(find "$SRC" -mindepth 1 2>/dev/null | wc -l)
  N_DST=$(find "$DEST" -mindepth 1 2>/dev/null | wc -l)
  [ "$N_SRC" -eq "$N_DST" ] || die "MISMATCH $SRC: $N_SRC entries vs $N_DST in $DEST — original left untouched"

  chown --reference="$(dirname "$SRC")" "$DEST" 2>/dev/null || true
  chmod --reference="$(dirname "$SRC")" "$DEST" 2>/dev/null || true

  mv "$SRC" "$SRC.premigration"
  mkdir -p "$SRC"                       # empty mountpoint for the declared mount
  chown --reference="$SRC.premigration" "$SRC" 2>/dev/null || true

  # Mount IMMEDIATELY, do not wait for a reboot. Between the mv above and the
  # mount, $SRC is an EMPTY DIRECTORY — for /home/diego/git that means every
  # repo on this machine vanishes from its expected path. Telling the operator
  # to "reboot afterwards" leaves that window open for as long as they take to
  # get there, with running tools reading an empty tree the whole time.
  if mount -o "subvol=$SUBVOL,compress=zstd,noatime" /dev/mapper/pool "$SRC" 2>/dev/null; then
    log "  mounted $SUBVOL at $SRC"
  else
    # Expected when the fileSystems entry has not been switched in yet — the
    # explicit -o above does not need fstab, so this is a real failure, not the
    # declarative one. Restore rather than leave the path empty.
    rmdir "$SRC" 2>/dev/null && mv "$SRC.premigration" "$SRC" \
      && die "mount failed for $SUBVOL — ORIGINAL RESTORED at $SRC, nothing lost"
    die "mount failed for $SUBVOL and $SRC could not be restored — data is at $SRC.premigration"
  fi
  log "  done — original kept at $SRC.premigration"
done <<< "$ENTRIES"

log "Next: switch, reboot (or mount -a), verify, then remove *.premigration"
