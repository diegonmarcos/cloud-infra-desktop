# p5-snapshot-boot — sha256 snapshot of the p5 superblock + groups 945-947
# (the corruption target) at boot, diffed against the last shutdown snapshot
#
# Extracted from configuration_p5_diagnostic.nix
# (systemd.services."p5-snapshot-boot".script). Runtime-data-driven: the raw
# device and the diagnostic output directory come from
# /etc/cloud-data/p5-diagnostic.json via jq at RUNTIME. Real binary paths
# (dd, sha256sum, awk) arrive via writeShellApplication runtimeInputs.
#
# Fail-loud: NO — mirrors the original exactly. This is a oneshot forensic
# snapshot for the 2026-05-15/16 p5 corruption incident, After=the mount +
# the preboot fsck; failing hard here would (per the module's own design)
# add risk to boot for a module whose entire purpose is passive evidence
# collection. Every step already logs via `logger` and continues.
set -u

CONFIG_JSON="${P5_DIAG_CONFIG_JSON:-/etc/cloud-data/p5-diagnostic.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t p5-diagnostic -p user.err "$CONFIG_JSON missing or unreadable"
  exit 0
fi

P5_RAW_DEVICE="$(jq -r '.p5_raw_device' "$CONFIG_JSON")"
DIAG_DIR="$(jq -r '.diag_dir' "$CONFIG_JSON")"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SNAP="$DIAG_DIR/snap-boot-$TS.sha"
mkdir -p "$DIAG_DIR"

# Superblock (first 4 KiB, contains primary + key metadata)
sb=$(dd if="$P5_RAW_DEVICE" bs=4096 count=1 2>/dev/null | sha256sum | awk '{print $1}')
echo "superblock(0..4KiB) $sb" > "$SNAP"

# Groups 945, 946, 947 — the corruption target.
# Group g block bitmap: blk = g * 32768 + 1 (block 0 = superblock copy, block 1 = bitmap)
for g in 945 946 947; do
  h=$(dd if="$P5_RAW_DEVICE" bs=4096 count=32 skip=$((g * 32768)) 2>/dev/null | sha256sum | awk '{print $1}')
  echo "group_${g}_first_128KiB $h" >> "$SNAP"
done

# Backup superblock (group 32 or wherever ext4 puts them)
bsb=$(dd if="$P5_RAW_DEVICE" bs=4096 count=1 skip=$((32 * 32768)) 2>/dev/null | sha256sum | awk '{print $1}')
echo "backup_superblock_g32 $bsb" >> "$SNAP"

logger -t p5-diagnostic -p user.info "boot snapshot written to $SNAP"

# Compare with last shutdown snapshot.
LAST_SHUTDOWN=""
for c in "$DIAG_DIR"/snap-shutdown-*.sha; do
  [ -e "$c" ] || continue
  if [ -z "$LAST_SHUTDOWN" ] || [ "$c" -nt "$LAST_SHUTDOWN" ]; then
    LAST_SHUTDOWN="$c"
  fi
done
if [ -n "$LAST_SHUTDOWN" ]; then
  echo "comparing boot snapshot to last shutdown: $LAST_SHUTDOWN"
  if diff -u "$LAST_SHUTDOWN" "$SNAP" > "$DIAG_DIR/diff-since-shutdown-$TS.log"; then
    logger -t p5-diagnostic -p user.info "p5 metadata UNCHANGED between shutdown and boot — corruption did NOT happen offline"
  else
    logger -t p5-diagnostic -p user.crit "p5 metadata CHANGED between shutdown and boot — see $DIAG_DIR/diff-since-shutdown-$TS.log"
    head -20 "$DIAG_DIR/diff-since-shutdown-$TS.log"
  fi
fi
