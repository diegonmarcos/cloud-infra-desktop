# rescue-invalidate-hibernate — rewrite the swapfile's header on rescue
# (noresume) boots so no stale hibernate signature can be resumed from later
#
# Extracted from configuration_rescue_invalidate_hibernate.nix
# (systemd.services."rescue-invalidate-hibernate".script). Runtime-data-driven:
# the swapfile path comes from /etc/cloud-data/rescue-invalidate-hibernate.json
# via jq at RUNTIME rather than being baked in from boot.json at Nix-eval
# time. Real binary paths (dd, awk, mkswap) arrive via writeShellApplication
# runtimeInputs.
#
# ConditionKernelCommandLine=noresume (systemd [Unit] key, stays Nix-side)
# is the hard guarantee this only ever runs on a rescue/noresume boot — see
# the module header for the full 2026-06-12 incident this design fixes.
#
# Fail-loud: NO for a missing swapfile or already-active swap (both `exit 0`
# with a log line) — mirrors the original exactly: those are expected,
# benign states (e.g. first boot before the swapfile exists), not failures.
# `set -eu` still makes any OTHER unexpected error (mkswap failing, etc.)
# abort the unit — unchanged from before extraction.
set -eu

CONFIG_JSON="${RESCUE_INVALIDATE_HIBERNATE_CONFIG_JSON:-/etc/cloud-data/rescue-invalidate-hibernate.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t rescue-invalidate-hibernate -p user.err "$CONFIG_JSON missing or unreadable"
  exit 1
fi

SWAP="$(jq -r '.swapfile' "$CONFIG_JSON")"

if [ ! -f "$SWAP" ]; then
  logger -t rescue-invalidate-hibernate -p user.warning \
    "swapfile $SWAP not present — nothing to invalidate"
  exit 0
fi

# Active swap: swapon already rewrote any S1SUSPEND signature when it
# activated the area, and mkswap would (rightly) refuse anyway.
if awk -v f="$SWAP" '$1 == f { found=1 } END { exit !found }' /proc/swaps; then
  logger -t rescue-invalidate-hibernate -p user.info \
    "swapfile $SWAP is active swap — signature already clean, skipping"
  exit 0
fi

# Header magic sits at byte 4086 of the swap area's first page:
# "SWAPSPACE2" = clean swap, "S1SUSPEND " = pending hibernate image.
MAGIC=$(dd if="$SWAP" bs=1 skip=4086 count=10 status=none | tr -d '\0')
logger -t rescue-invalidate-hibernate -p user.info \
  "swapfile $SWAP header magic before invalidation: '$MAGIC'"

# Rewrite the swap header INSIDE THE FILE. Never touch the partition:
# the backing device is the ext4 filesystem itself (2026-06-12 incident).
mkswap "$SWAP" >/dev/null

logger -t rescue-invalidate-hibernate -p user.warning \
  "rescue boot: swap header of $SWAP rewritten (was: '$MAGIC', now: SWAPSPACE2). No stale resume possible."
