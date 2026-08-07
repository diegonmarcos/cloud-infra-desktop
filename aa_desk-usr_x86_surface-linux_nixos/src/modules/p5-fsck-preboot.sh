# p5-fsck-preboot — read-only fsck.ext4 check of Shared-Lib (p5) BEFORE
# local-fs.target, run first so a corruption from the PREVIOUS boot is
# visible at THIS boot's startup
#
# Extracted from configuration_p5_diagnostic.nix
# (systemd.services."p5-fsck-preboot".script). Runtime-data-driven: the
# device to check and the diagnostic output directory come from
# /etc/cloud-data/p5-diagnostic.json via jq at RUNTIME. Real binary paths
# (fsck.ext4, wall) arrive via writeShellApplication runtimeInputs.
#
# Fail-loud: NO — mirrors the original exactly. This runs DefaultDependencies
# = false, Before=local-fs.target, at the earliest point in boot, purely to
# capture forensic evidence for the 2026-05-15/16 p5 corruption incident. A
# hard failure here (device missing, fsck reporting errors) must NOT delay or
# block local-fs.target / the rest of boot — the script already `exit 0`s on
# a missing device and treats a dirty fsck as a logged CRIT, not a script
# failure, exactly as before extraction.
set -u

CONFIG_JSON="${P5_DIAG_CONFIG_JSON:-/etc/cloud-data/p5-diagnostic.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t p5-diagnostic -p user.err "$CONFIG_JSON missing or unreadable"
  exit 0
fi

P5_DEVICE="$(jq -r '.p5_device' "$CONFIG_JSON")"
DIAG_DIR="$(jq -r '.diag_dir' "$CONFIG_JSON")"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$DIAG_DIR"
LOG="$DIAG_DIR/fsck-preboot-$TS.log"

echo "[p5-diag] boot $TS — checking $P5_DEVICE with fsck.ext4 -nfv (read-only)" | tee -a "$LOG"
if [ ! -e "$P5_DEVICE" ]; then
  echo "[p5-diag] CRITICAL: $P5_DEVICE not present — partition table issue?" | tee -a "$LOG"
  logger -t p5-diagnostic -p user.crit "preboot fsck SKIPPED — device $P5_DEVICE missing"
  exit 0
fi

if fsck.ext4 -nfv "$P5_DEVICE" 2>&1 | tee -a "$LOG"; then
  echo "[p5-diag] boot $TS — fsck CLEAN. p5 was healthy at start of this boot." | tee -a "$LOG"
  logger -t p5-diagnostic -p user.info "preboot fsck CLEAN at $TS"
else
  rc=$?
  echo "[p5-diag] boot $TS — fsck reported ERRORS (exit $rc). PREVIOUS BOOT CORRUPTED p5." | tee -a "$LOG"
  logger -t p5-diagnostic -p user.crit "preboot fsck FAILED (exit $rc) — previous boot corrupted p5"
  # Echo to wall so console user sees it pre-login.
  echo "*** p5 (/mnt/shared-lib) WAS CORRUPTED BY PREVIOUS BOOT — see $LOG ***" | wall -n 2>/dev/null || true
fi
