#!/usr/bin/env bash
# btrfs-qgroup-setup.sh — idempotent, runtime-data-driven btrfs qgroup setup.
#
# Fully runtime-data-driven: reads btrfs_qgroups.* from CONFIG_JSON
# (/etc/cloud-data/disk-protection.json) via jq. Nothing is baked in by Nix.
# See cloud-data-disk-protection.json's btrfs_qgroups._comment for WHY qgroups
# are required at all (per-subvolume accounting does not exist without them)
# and for the activation-cost warning (first `btrfs quota enable` triggers a
# full one-time rescan — IO/CPU heavy).
#
# Safe to run on every boot:
#   - exits 0 immediately if btrfs_qgroups.enabled is false
#   - only calls `btrfs quota enable` if quotas are not already enabled
#     (checked first via `btrfs qgroup show`, never called unconditionally)
#   - only calls `btrfs qgroup limit` for entries that declare limit_gib, and
#     only when the current kernel-side max_rfer differs from the desired
#     value (so a no-op boot performs zero mutating btrfs calls)
#
# Built via pkgs.writeShellApplication — runtimeInputs supplies btrfs-progs,
# jq, coreutils.
set -u

CONFIG_JSON="${DISK_PROTECTION_JSON:-/etc/cloud-data/disk-protection.json}"

if [ ! -r "$CONFIG_JSON" ]; then
  logger -t btrfs-qgroup-setup -p user.err "btrfs-qgroup-setup: CONFIG MISSING/UNREADABLE at $CONFIG_JSON — refusing to run"
  echo "[btrfs-qgroup-setup] FATAL: config missing/unreadable at $CONFIG_JSON" >&2
  exit 1
fi
if ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t btrfs-qgroup-setup -p user.err "btrfs-qgroup-setup: CONFIG UNPARSEABLE at $CONFIG_JSON — refusing to run"
  echo "[btrfs-qgroup-setup] FATAL: config unparseable at $CONFIG_JSON" >&2
  exit 1
fi

QGROUPS_ENABLED=$(jq -r '.btrfs_qgroups.enabled // false' "$CONFIG_JSON")
if [ "$QGROUPS_ENABLED" != "true" ]; then
  echo "[btrfs-qgroup-setup] btrfs_qgroups.enabled is false — nothing to do"
  exit 0
fi

FS_MOUNT=$(jq -r '.btrfs_qgroups.filesystem_mount // "/"' "$CONFIG_JSON")

if ! mountpoint -q "$FS_MOUNT" 2>/dev/null; then
  logger -t btrfs-qgroup-setup -p user.err "btrfs-qgroup-setup: $FS_MOUNT is NOT a mountpoint — refusing to run"
  echo "[btrfs-qgroup-setup] FATAL: $FS_MOUNT is not a mountpoint" >&2
  exit 1
fi

# ── Enable quotas ONLY if not already enabled. `btrfs qgroup show` on a
# filesystem with quotas disabled prints a distinct error on stderr; on a
# filesystem with quotas enabled it succeeds (even with zero qgroups yet).
# This check is what keeps the script a no-op on every boot after the first.
if btrfs qgroup show "$FS_MOUNT" >/dev/null 2>&1; then
  echo "[btrfs-qgroup-setup] quotas already enabled on $FS_MOUNT — skipping quota enable"
else
  echo "[btrfs-qgroup-setup] quotas NOT enabled on $FS_MOUNT — enabling now (first-time rescan, IO/CPU heavy)"
  logger -t btrfs-qgroup-setup -p user.notice "btrfs-qgroup-setup: enabling quotas on $FS_MOUNT — triggers a one-time full rescan"
  if ! btrfs quota enable "$FS_MOUNT" 2>&1; then
    logger -t btrfs-qgroup-setup -p user.err "btrfs-qgroup-setup: 'btrfs quota enable $FS_MOUNT' FAILED"
    echo "[btrfs-qgroup-setup] FATAL: btrfs quota enable $FS_MOUNT failed" >&2
    exit 1
  fi
fi

# ── Per-subvolume limits — apply/update only entries with a declared limit_gib.
while IFS=$'\t' read -r SUBMOUNT LIMIT_GIB; do
  [ -n "$SUBMOUNT" ] || continue
  if [ "$LIMIT_GIB" = "null" ] || [ -z "$LIMIT_GIB" ]; then
    echo "[btrfs-qgroup-setup] $SUBMOUNT: no limit_gib declared — accounting only, no kernel-enforced cap"
    continue
  fi
  if ! [[ "$LIMIT_GIB" =~ ^[0-9]+$ ]]; then
    echo "[btrfs-qgroup-setup] $SUBMOUNT: limit_gib '$LIMIT_GIB' is not a positive integer — skipped" >&2
    continue
  fi
  if ! mountpoint -q "$SUBMOUNT" 2>/dev/null; then
    logger -t btrfs-qgroup-setup -p user.warning "btrfs-qgroup-setup: $SUBMOUNT is NOT a mountpoint — SKIPPED"
    echo "[btrfs-qgroup-setup] $SUBMOUNT: NOT MOUNTED — skipped"
    continue
  fi

  # NOT anchored, and $NF rather than -F': ' $2. `btrfs subvolume show` indents
  # every field with a TAB, so the real line is "\tSubvolume ID: \t\t257": the
  # old /^Subvolume ID:/ anchor could never match, and even on a match `tr -d ' '`
  # strips spaces but NOT the tabs that -F': ' left in $2. Every subvolume was
  # therefore "could not resolve subvolume ID — skipped" and NO limit was ever
  # applied (btrfs qgroup show reported max_rfer=none across the board). This hid
  # until 2026-08-11 because the loop bails out earlier when limit_gib is unset,
  # so the whole-file default of null meant this line was never reached.
  SUBVOLID=$(btrfs subvolume show "$SUBMOUNT" 2>/dev/null | awk '/Subvolume ID:/ {print $NF}' | tr -dc '0-9')
  if ! [[ "$SUBVOLID" =~ ^[0-9]+$ ]]; then
    echo "[btrfs-qgroup-setup] $SUBMOUNT: could not resolve subvolume ID — skipped" >&2
    continue
  fi

  DESIRED_BYTES=$(( LIMIT_GIB * 1024 * 1024 * 1024 ))

  CURRENT_MAXRFER=""
  # -re is REQUIRED for $4 to be max_rfer. Without it `btrfs qgroup show` emits
  # only qgroupid/rfer/excl/path, so $4 was the PATH — this read '@home-diego'
  # where it expected a byte count. Effect: the "already set — no change" test
  # could never match, so every activation re-applied an identical limit and
  # logged "(was '@home-diego')" instead of the previous cap. Harmless but not
  # idempotent, and the same missing flag is a REAL bug in disk-watchdog.sh.
  CURRENT_MAXRFER=$(btrfs qgroup show --raw -ref "$SUBMOUNT" 2>/dev/null | awk -v id="0/$SUBVOLID" '$1==id {print $4}')

  if [ "$CURRENT_MAXRFER" = "$DESIRED_BYTES" ]; then
    echo "[btrfs-qgroup-setup] $SUBMOUNT: max_rfer already ${LIMIT_GIB}GiB — no change"
    continue
  fi

  echo "[btrfs-qgroup-setup] $SUBMOUNT: setting max_rfer to ${LIMIT_GIB}GiB (was '${CURRENT_MAXRFER:-unset}')"
  if ! btrfs qgroup limit "${LIMIT_GIB}G" "$SUBMOUNT" 2>&1; then
    logger -t btrfs-qgroup-setup -p user.err "btrfs-qgroup-setup: 'btrfs qgroup limit ${LIMIT_GIB}G $SUBMOUNT' FAILED"
    echo "[btrfs-qgroup-setup] $SUBMOUNT: btrfs qgroup limit FAILED" >&2
  fi
done < <(jq -r '.btrfs_qgroups.subvolumes[]? | [.mount, (.limit_gib // "null")] | @tsv' "$CONFIG_JSON")

echo "[btrfs-qgroup-setup] done"
