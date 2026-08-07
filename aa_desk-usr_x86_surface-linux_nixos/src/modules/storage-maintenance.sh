#!/usr/bin/env bash
# storage-maintenance.sh — daily deep storage housekeeping.
#
# Fully runtime-data-driven: ALL thresholds, mounts, atime windows, journal
# vacuum settings, nix GC window, docker builder cache cap and btrfs
# balance/scrub thresholds are read from CONFIG_JSON
# (/etc/cloud-data/disk-protection.json, key `.storage_maintenance`) via jq.
# Nothing is baked in by Nix interpolation. See
# configuration_system-protection-storage.nix for how this script is wired
# (writeShellApplication) — the JSON itself is already deployed by
# configuration_system-protection-disk.nix (environment.etc), so this module
# does not redeclare it.
#
# 1. Swap/cache cleanup (drop caches, trim zram)
# 2. Journal vacuum
# 3. Nix garbage collection
# 4. Docker/Podman cleanup
# 5. Btrfs chunk consolidation (balance)
# 6. Btrfs scrub (monthly)
# 7. SSD TRIM
set -euo pipefail

CONFIG_JSON="${DISK_PROTECTION_JSON:-/etc/cloud-data/disk-protection.json}"

# Fail LOUDLY and safely if config is missing/unreadable/unparseable — a
# maintenance job that reads no config must never conclude "everything is
# fine" and skip cleanup silently.
if [ ! -r "$CONFIG_JSON" ]; then
  logger -t storage-maintenance -p user.err "storage-maintenance: CONFIG MISSING/UNREADABLE at $CONFIG_JSON — refusing to run with no thresholds"
  echo "[storage-maintenance] FATAL: config missing/unreadable at $CONFIG_JSON" >&2
  exit 1
fi
if ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t storage-maintenance -p user.err "storage-maintenance: CONFIG UNPARSEABLE at $CONFIG_JSON — refusing to run with no thresholds"
  echo "[storage-maintenance] FATAL: config unparseable at $CONFIG_JSON" >&2
  exit 1
fi

BTRFS_MOUNTS=$(jq -r '(.storage_maintenance.btrfs_mounts // []) | join(" ")' "$CONFIG_JSON")
TMP_ATIME_DAYS=$(jq -r '.storage_maintenance.tmp_atime_days // 1' "$CONFIG_JSON")
VAR_TMP_ATIME_DAYS=$(jq -r '.storage_maintenance.var_tmp_atime_days // 1' "$CONFIG_JSON")
USER_CACHE_ATIME_DAYS=$(jq -r '.storage_maintenance.user_cache_atime_days // 7' "$CONFIG_JSON")
JOURNAL_VACUUM_TIME=$(jq -r '.storage_maintenance.journal.vacuum_time // "7d"' "$CONFIG_JSON")
JOURNAL_VACUUM_SIZE=$(jq -r '.storage_maintenance.journal.vacuum_size // "200M"' "$CONFIG_JSON")
NIX_GC_KEEP_DAYS=$(jq -r '.storage_maintenance.nix_gc_keep_days // 7' "$CONFIG_JSON")
DOCKER_BUILDER_KEEP_STORAGE=$(jq -r '.storage_maintenance.docker.builder_keep_storage // "2G"' "$CONFIG_JSON")
BALANCE_DATA_USAGE_PCT=$(jq -r '.storage_maintenance.btrfs.balance_data_usage_pct // 85' "$CONFIG_JSON")
BALANCE_METADATA_USAGE_PCT=$(jq -r '.storage_maintenance.btrfs.balance_metadata_usage_pct // 90' "$CONFIG_JSON")
SCRUB_DAY_OF_MONTH=$(jq -r '.storage_maintenance.btrfs.scrub_day_of_month // "01"' "$CONFIG_JSON")
FSTRIM_ENABLED=$(jq -r '.storage_maintenance.fstrim_enabled // true' "$CONFIG_JSON")

# ── Helper: snapshot btrfs chunk allocation for a mount ─────────────────────
# Emits ONLY the bare values, space-separated, in this fixed field order
# (contract with callers, which `read` them positionally):
#   size alloc unalloc used data_pct meta_pct
snapshot_chunks() {
  local mount="$1"
  btrfs filesystem usage "$mount" 2>/dev/null | awk '
    /^Overall:/ { in_overall=1 }
    in_overall && /Device size:/ { gsub(/[^0-9.]/, "", $3); size=$3 }
    in_overall && /Device allocated:/ { gsub(/[^0-9.]/, "", $3); alloc=$3 }
    in_overall && /Device unallocated:/ { gsub(/[^0-9.]/, "", $3); unalloc=$3 }
    in_overall && /Used:/ { gsub(/[^0-9.]/, "", $2); used=$2; in_overall=0 }
    /^Data,/ { in_data=1 }
    in_data && /Size:/ { split($0, a, "("); gsub(/[^0-9.]/, "", a[2]); data_pct=a[2]; in_data=0 }
    /^Metadata,/ { in_meta=1 }
    in_meta && /Size:/ { split($0, a, "("); gsub(/[^0-9.]/, "", a[2]); meta_pct=a[2]; in_meta=0 }
    END {
      printf "%s %s %s %s %s %s", size, alloc, unalloc, used, data_pct, meta_pct
    }
  '
}

# ── Helper: print chunk summary ────────────────────────────────────
print_chunks() {
  local label="$1" mount="$2"
  local size alloc unalloc used data_pct meta_pct
  read -r size alloc unalloc used data_pct meta_pct <<< "$(snapshot_chunks "$mount")"
  echo "  [$label] $mount:"
  echo "    Used: ${used}GiB / ${size}GiB"
  echo "    Allocated: ${alloc}GiB  |  Unallocated: ${unalloc}GiB"
  echo "    Data chunks: ${data_pct}%  |  Metadata chunks: ${meta_pct}%"
}

# ═══════════════════════════════════════════════════════════════════
# PHASE 0: BEFORE SNAPSHOT
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "── BEFORE ──────────────────────────────────────────────────────"
for mount in $BTRFS_MOUNTS; do
  if mountpoint -q "$mount" 2>/dev/null; then
    print_chunks "BEFORE" "$mount"
  fi
done

SWAP_BEFORE=$(free -m | awk '/^Swap:/ { print $3 }')
echo "  Swap used: ${SWAP_BEFORE}MB"
echo ""

# ═══════════════════════════════════════════════════════════════════
# PHASE 1: CACHE & SWAP CLEANUP
# ═══════════════════════════════════════════════════════════════════
echo "── Phase 1: Cache & Swap cleanup ───────────────────────────────"

# Sync pending writes
sync

# Drop dentries + inodes (not page cache — that's useful)
echo 2 > /proc/sys/vm/drop_caches
echo "  Dropped dentries + inodes"

# Clear old /tmp and /var/tmp files
find /tmp -type f -atime "+${TMP_ATIME_DAYS}" -delete 2>/dev/null || true
find /var/tmp -type f -atime "+${VAR_TMP_ATIME_DAYS}" -delete 2>/dev/null || true
echo "  Cleaned /tmp and /var/tmp (files >${TMP_ATIME_DAYS} day)"

# Clear user caches older than 7 days
find /home/*/. -maxdepth 0 2>/dev/null | while read -r home; do
  find "$home/.cache" -type f -atime "+${USER_CACHE_ATIME_DAYS}" -delete 2>/dev/null || true
done
echo "  Cleaned user caches (>${USER_CACHE_ATIME_DAYS} days)"

# Compact zram (if available) — reset to reclaim fragmented pages
if [ -f /sys/block/zram0/reset ]; then
  # Only log swap pressure, don't reset zram (would kill swap contents)
  SWAP_AFTER_CACHE=$(free -m | awk '/^Swap:/ { print $3 }')
  echo "  Swap: ${SWAP_BEFORE}MB → ${SWAP_AFTER_CACHE}MB after cache drop"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════
# PHASE 2: JOURNAL CLEANUP
# ═══════════════════════════════════════════════════════════════════
echo "── Phase 2: Journal cleanup ────────────────────────────────────"

JOURNAL_BEFORE=$(journalctl --disk-usage 2>/dev/null | awk '{ print $7, $8 }')
echo "  Journal before: $JOURNAL_BEFORE"

journalctl "--vacuum-time=${JOURNAL_VACUUM_TIME}" "--vacuum-size=${JOURNAL_VACUUM_SIZE}" 2>/dev/null || true

JOURNAL_AFTER=$(journalctl --disk-usage 2>/dev/null | awk '{ print $7, $8 }')
echo "  Journal after:  $JOURNAL_AFTER"
echo ""

# ═══════════════════════════════════════════════════════════════════
# PHASE 3: NIX GARBAGE COLLECTION
# ═══════════════════════════════════════════════════════════════════
echo "── Phase 3: Nix garbage collection ─────────────────────────────"

STORE_BEFORE=$(du -sb /nix/store 2>/dev/null | awk '{ print $1 }')

nix-collect-garbage --delete-older-than "${NIX_GC_KEEP_DAYS}d" 2>&1 | tail -3
nix-store --optimise 2>&1 | tail -3 || true

STORE_AFTER=$(du -sb /nix/store 2>/dev/null | awk '{ print $1 }')
FREED=$(( (STORE_BEFORE - STORE_AFTER) / 1048576 ))
echo "  Nix store freed: ${FREED}MB"
echo ""

# ═══════════════════════════════════════════════════════════════════
# PHASE 4: DOCKER CLEANUP
# ═══════════════════════════════════════════════════════════════════
echo "── Phase 4: Docker cleanup ─────────────────────────────────────"

if command -v docker >/dev/null 2>&1; then
  docker container prune -f 2>/dev/null || true
  docker image prune -f 2>/dev/null || true
  docker builder prune -f "--keep-storage=${DOCKER_BUILDER_KEEP_STORAGE}" 2>/dev/null || true
  echo "  Docker: pruned containers, dangling images, build cache"
else
  echo "  Docker: not available, skipping"
fi

if command -v podman >/dev/null 2>&1; then
  podman system prune -f 2>/dev/null || true
  echo "  Podman: pruned"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════
# PHASE 5: BTRFS CHUNK CONSOLIDATION
# ═══════════════════════════════════════════════════════════════════
echo "── Phase 5: Btrfs chunk consolidation ──────────────────────────"

for mount in $BTRFS_MOUNTS; do
  if ! mountpoint -q "$mount" 2>/dev/null; then
    echo "  $mount: not a mountpoint, skipping"
    continue
  fi

  FS_TYPE=$(stat -f -c '%T' "$mount" 2>/dev/null)
  if [ "$FS_TYPE" != "btrfs" ]; then
    echo "  $mount: not btrfs ($FS_TYPE), skipping"
    continue
  fi

  echo "  [$mount] Balancing data chunks (<${BALANCE_DATA_USAGE_PCT}% usage)..."
  btrfs balance start "-dusage=${BALANCE_DATA_USAGE_PCT}" "$mount" 2>&1 || echo "  [$mount] Data balance: no work needed or error"

  echo "  [$mount] Balancing metadata chunks (<${BALANCE_METADATA_USAGE_PCT}% usage)..."
  btrfs balance start "-musage=${BALANCE_METADATA_USAGE_PCT}" "$mount" 2>&1 || echo "  [$mount] Metadata balance: no work needed or error"

  echo ""
done

# ═══════════════════════════════════════════════════════════════════
# PHASE 6: BTRFS SCRUB (monthly — 1st of month only)
# ═══════════════════════════════════════════════════════════════════
DAY=$(date +%d)
if [ "$DAY" = "$SCRUB_DAY_OF_MONTH" ]; then
  echo "── Phase 6: Btrfs scrub (monthly) ──────────────────────────────"
  for mount in $BTRFS_MOUNTS; do
    if mountpoint -q "$mount" 2>/dev/null; then
      FS_TYPE=$(stat -f -c '%T' "$mount" 2>/dev/null)
      if [ "$FS_TYPE" = "btrfs" ]; then
        echo "  [$mount] Starting scrub..."
        btrfs scrub start -B "$mount" 2>&1 || echo "  [$mount] Scrub error"
      fi
    fi
  done
  echo ""
else
  echo "── Phase 6: Btrfs scrub — skipped (not 1st of month) ──────────"
  echo ""
fi

# ═══════════════════════════════════════════════════════════════════
# PHASE 7: FSTRIM (SSD discard)
# ═══════════════════════════════════════════════════════════════════
if [ "$FSTRIM_ENABLED" = "true" ]; then
  echo "── Phase 7: SSD TRIM ───────────────────────────────────────────"
  fstrim -av 2>&1 || echo "  fstrim: error or not supported"
  echo ""
else
  echo "── Phase 7: SSD TRIM — skipped (disabled in config) ────────────"
  echo ""
fi

# ═══════════════════════════════════════════════════════════════════
# AFTER SNAPSHOT + SUMMARY
# ═══════════════════════════════════════════════════════════════════
echo "── AFTER ───────────────────────────────────────────────────────"
for mount in $BTRFS_MOUNTS; do
  if mountpoint -q "$mount" 2>/dev/null; then
    print_chunks "AFTER" "$mount"
  fi
done

SWAP_AFTER=$(free -m | awk '/^Swap:/ { print $3 }')
echo "  Swap used: ${SWAP_AFTER}MB (was ${SWAP_BEFORE}MB)"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  STORAGE MAINTENANCE COMPLETE — $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════════════════"
