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
  btrfsMounts = [ "/nix" "/home/diego" ];
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
    path = with pkgs; [
      coreutils
      util-linux
      btrfs-progs
      nix
      systemd
      gawk
      procps
      findutils
    ];
    script = ''
      set -euo pipefail

      echo "═══════════════════════════════════════════════════════════════════"
      echo "  STORAGE MAINTENANCE — $(date '+%Y-%m-%d %H:%M:%S')"
      echo "═══════════════════════════════════════════════════════════════════"

      # ── Helper: snapshot btrfs chunk stats ──────────────────────────────
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
            printf "size=%s alloc=%s unalloc=%s used=%s data_pct=%s meta_pct=%s", size, alloc, unalloc, used, data_pct, meta_pct
          }
        '
      }

      # ── Helper: print chunk summary ────────────────────────────────────
      print_chunks() {
        local label="$1" mount="$2"
        local stats
        stats=$(snapshot_chunks "$mount")
        eval "$stats"
        echo "  [$label] $mount:"
        echo "    Used: ''${used}GiB / ''${size}GiB"
        echo "    Allocated: ''${alloc}GiB  |  Unallocated: ''${unalloc}GiB"
        echo "    Data chunks: ''${data_pct}%  |  Metadata chunks: ''${meta_pct}%"
      }

      # ═══════════════════════════════════════════════════════════════════
      # PHASE 0: BEFORE SNAPSHOT
      # ═══════════════════════════════════════════════════════════════════
      echo ""
      echo "── BEFORE ──────────────────────────────────────────────────────"
      for mount in ${lib.concatStringsSep " " btrfsMounts}; do
        if mountpoint -q "$mount" 2>/dev/null; then
          print_chunks "BEFORE" "$mount"
        fi
      done

      SWAP_BEFORE=$(free -m | awk '/^Swap:/ { print $3 }')
      echo "  Swap used: ''${SWAP_BEFORE}MB"
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
      find /tmp -type f -atime +1 -delete 2>/dev/null || true
      find /var/tmp -type f -atime +1 -delete 2>/dev/null || true
      echo "  Cleaned /tmp and /var/tmp (files >1 day)"

      # Clear user caches older than 7 days
      find /home/*/. -maxdepth 0 2>/dev/null | while read home; do
        find "$home/.cache" -type f -atime +7 -delete 2>/dev/null || true
      done
      echo "  Cleaned user caches (>7 days)"

      # Compact zram (if available) — reset to reclaim fragmented pages
      if [ -f /sys/block/zram0/reset ]; then
        # Only log swap pressure, don't reset zram (would kill swap contents)
        SWAP_AFTER_CACHE=$(free -m | awk '/^Swap:/ { print $3 }')
        echo "  Swap: ''${SWAP_BEFORE}MB → ''${SWAP_AFTER_CACHE}MB after cache drop"
      fi

      echo ""

      # ═══════════════════════════════════════════════════════════════════
      # PHASE 2: JOURNAL CLEANUP
      # ═══════════════════════════════════════════════════════════════════
      echo "── Phase 2: Journal cleanup ────────────────────────────────────"

      JOURNAL_BEFORE=$(journalctl --disk-usage 2>/dev/null | awk '{ print $7, $8 }')
      echo "  Journal before: $JOURNAL_BEFORE"

      journalctl --vacuum-time=7d --vacuum-size=200M 2>/dev/null || true

      JOURNAL_AFTER=$(journalctl --disk-usage 2>/dev/null | awk '{ print $7, $8 }')
      echo "  Journal after:  $JOURNAL_AFTER"
      echo ""

      # ═══════════════════════════════════════════════════════════════════
      # PHASE 3: NIX GARBAGE COLLECTION
      # ═══════════════════════════════════════════════════════════════════
      echo "── Phase 3: Nix garbage collection ─────────────────────────────"

      STORE_BEFORE=$(du -sb /nix/store 2>/dev/null | awk '{ print $1 }')

      nix-collect-garbage --delete-older-than 7d 2>&1 | tail -3
      nix-store --optimise 2>&1 | tail -3 || true

      STORE_AFTER=$(du -sb /nix/store 2>/dev/null | awk '{ print $1 }')
      FREED=$(( (STORE_BEFORE - STORE_AFTER) / 1048576 ))
      echo "  Nix store freed: ''${FREED}MB"
      echo ""

      # ═══════════════════════════════════════════════════════════════════
      # PHASE 4: DOCKER CLEANUP
      # ═══════════════════════════════════════════════════════════════════
      echo "── Phase 4: Docker cleanup ─────────────────────────────────────"

      if command -v docker >/dev/null 2>&1; then
        docker container prune -f 2>/dev/null || true
        docker image prune -f 2>/dev/null || true
        docker builder prune -f --keep-storage=2G 2>/dev/null || true
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

      for mount in ${lib.concatStringsSep " " btrfsMounts}; do
        if ! mountpoint -q "$mount" 2>/dev/null; then
          echo "  $mount: not a mountpoint, skipping"
          continue
        fi

        FS_TYPE=$(stat -f -c '%T' "$mount" 2>/dev/null)
        if [ "$FS_TYPE" != "btrfs" ]; then
          echo "  $mount: not btrfs ($FS_TYPE), skipping"
          continue
        fi

        echo "  [$mount] Balancing data chunks (<85% usage)..."
        btrfs balance start -dusage=85 "$mount" 2>&1 || echo "  [$mount] Data balance: no work needed or error"

        echo "  [$mount] Balancing metadata chunks (<90% usage)..."
        btrfs balance start -musage=90 "$mount" 2>&1 || echo "  [$mount] Metadata balance: no work needed or error"

        echo ""
      done

      # ═══════════════════════════════════════════════════════════════════
      # PHASE 6: BTRFS SCRUB (monthly — 1st of month only)
      # ═══════════════════════════════════════════════════════════════════
      DAY=$(date +%d)
      if [ "$DAY" = "01" ]; then
        echo "── Phase 6: Btrfs scrub (monthly) ──────────────────────────────"
        for mount in ${lib.concatStringsSep " " btrfsMounts}; do
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
      echo "── Phase 7: SSD TRIM ───────────────────────────────────────────"
      fstrim -av 2>&1 || echo "  fstrim: error or not supported"
      echo ""

      # ═══════════════════════════════════════════════════════════════════
      # AFTER SNAPSHOT + SUMMARY
      # ═══════════════════════════════════════════════════════════════════
      echo "── AFTER ───────────────────────────────────────────────────────"
      for mount in ${lib.concatStringsSep " " btrfsMounts}; do
        if mountpoint -q "$mount" 2>/dev/null; then
          print_chunks "AFTER" "$mount"
        fi
      done

      SWAP_AFTER=$(free -m | awk '/^Swap:/ { print $3 }')
      echo "  Swap used: ''${SWAP_AFTER}MB (was ''${SWAP_BEFORE}MB)"
      echo ""
      echo "═══════════════════════════════════════════════════════════════════"
      echo "  STORAGE MAINTENANCE COMPLETE — $(date '+%Y-%m-%d %H:%M:%S')"
      echo "═══════════════════════════════════════════════════════════════════"
    '';
  };
}
