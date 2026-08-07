# session-checkpoint — read-only btrfs snapshot of the home subvolume
#
# Extracted from configuration_session-checkpoint.nix's `mkCheckpointScript`
# (a Nix function called 3 times with a different literal tag — "periodic",
# "shutdown", "hibernate" — to produce 3 near-identical Nix-interpolated
# shell bodies for the 3 systemd services). Now ONE runtime script; which
# checkpoint is being taken is selected by name (arg 1), and policy
# (btrfs_root, source_subvol, snapshot_dir, retention_count, notify) is read
# at RUNTIME via jq from /etc/cloud-data/session-checkpoint.json — the SAME
# file configuration_session-checkpoint.nix already treats as the single
# source of truth (builtins.fromJSON), so nothing is hand-authored here.
#
# Usage: session-checkpoint <tag>   (tag: periodic | shutdown | hibernate)
#
# State/contract notes (preserved byte-for-byte from the original):
#   - source subvol not available (pool unmounted, rescue context) => log a
#     warning and exit 0 (never fail the caller — same as before).
#   - snapshot name: <UTC timestamp>-<tag>, e.g. 2026-08-08T12-00-00Z-periodic
#   - desktop notification only for tag=periodic (session still ending for
#     shutdown/hibernate; no bus to notify), gated by checkpoint.notify.
#   - prune: keep only the newest $KEEP snapshots (retention_count).
set -euo pipefail

TAG="${1:?session-checkpoint: tag required (periodic|shutdown|hibernate)}"
CONFIG_JSON="${SESSION_CHECKPOINT_CONFIG_JSON:-/etc/cloud-data/session-checkpoint.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t session-checkpoint -p user.err "$CONFIG_JSON missing or unreadable"
  exit 1
fi

ROOT="$(jq -r '.checkpoint.btrfs_root' "$CONFIG_JSON")"
SRC_SUBVOL="$(jq -r '.checkpoint.source_subvol' "$CONFIG_JSON")"
SNAP_DIR="$(jq -r '.checkpoint.snapshot_dir' "$CONFIG_JSON")"
KEEP="$(jq -r '.checkpoint.retention_count' "$CONFIG_JSON")"
NOTIFY="$(jq -r '.checkpoint.notify // false' "$CONFIG_JSON")"

SRC="$ROOT/$SRC_SUBVOL"
DEST_DIR="$ROOT/$SNAP_DIR"

# Pool not mounted (rescue context, mid-recovery) => skip, never fail.
if ! btrfs subvolume show "$SRC" >/dev/null 2>&1; then
  logger -t session-checkpoint -p user.warning \
    "source subvol $SRC not available — skipping $TAG checkpoint"
  exit 0
fi

# Parent of the snapshot tree must be a subvolume too (so checkpoints are
# excluded from any future snapshot of the top level). Create on first run.
PARENT="$ROOT/$(dirname "$SNAP_DIR")"
if ! btrfs subvolume show "$PARENT" >/dev/null 2>&1; then
  btrfs subvolume create "$PARENT"
fi
mkdir -p "$DEST_DIR"

TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)-$TAG"
btrfs subvolume snapshot -r "$SRC" "$DEST_DIR/$TS" >/dev/null
sync
logger -t session-checkpoint -p user.info \
  "$TAG session checkpoint written: $DEST_DIR/$TS"

# Desktop notification confirming the local snapshot was saved. PERIODIC
# only — at shutdown/hibernate the session is tearing down, no bus to
# notify. Runs as each logged-in user (runuser + their DBus/XDG_RUNTIME_DIR),
# so it follows the KDE dark theme. Gated by checkpoint.notify in the JSON.
# NOTE: the test is != "shutdown" only, NOT also != "hibernate". The comment
# above reads as if hibernate should be excluded too, but the original Nix
# guard excluded shutdown alone, so hibernate DID notify. Extraction must not
# change behaviour; if excluding hibernate is actually wanted, that is a
# separate deliberate change.
if [ "$NOTIFY" = "true" ] && [ "$TAG" != "shutdown" ]; then
  # find, not ls -1, for SC2012 (non-alphanumeric-safe listing).
  KEPT="$(find "$DEST_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | wc -l)" || KEPT=0
  for udir in /run/user/*; do
    [ -d "$udir" ] || continue
    uid="$(basename "$udir")"
    user="$(awk -F: -v u="$uid" '$3==u{print $1; exit}' /etc/passwd)" || continue
    [ -n "$user" ] || continue
    bus="$udir/bus"
    [ -S "$bus" ] || continue
    runuser -u "$user" -- env \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" XDG_RUNTIME_DIR="$udir" \
      notify-send -a "Session" -i document-save-symbolic -t 4000 \
        "Session snapshot saved" "Local btrfs checkpoint written to disk:
$DEST_DIR/$TS
($KEPT kept, newest-$KEEP retained)" || true
  done
fi

# Prune: keep the newest $KEEP (timestamp names sort chronologically).
while IFS= read -r old; do
  [ -n "$old" ] || continue
  if btrfs subvolume delete "$DEST_DIR/$old" >/dev/null; then
    logger -t session-checkpoint -p user.info "pruned checkpoint $old"
  fi
done < <(find "$DEST_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | head -n -"$KEEP")
