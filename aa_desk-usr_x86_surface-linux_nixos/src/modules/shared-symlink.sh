# shared-symlink — symlink an @shared-backed directory into place at boot
#
# Extracted from configuration_persistence.nix (the near-identical
# ExecStart bodies of systemd.services."networkmanager-persistent" and
# "bluetooth-persistent" — networkmanager-shared-symlink /
# bluetooth-shared-symlink). Both are now this ONE data-driven script; which
# entry to apply is selected at runtime by name (arg 1) from
# /etc/cloud-data/shared-symlinks.json via jq, instead of being two
# hand-duplicated Nix-interpolated heredocs.
#
# Usage: shared-symlink <entry-name>
#
# JSON entry schema (array of objects), field order/meaning:
#   name          - selector matched against arg 1
#   label         - prefix used in log lines, e.g. "NETWORKMANAGER"
#   mount_check   - path that must be a mountpoint before proceeding
#   create_dirs   - array of directories to mkdir -p + chmod dir_perm
#   dir_perm      - chmod mode applied to each entry in create_dirs
#   target_parent - parent directory of the symlink target to mkdir -p first
#                   (empty string if none needed)
#   target        - symlink path to (re)create
#   source        - symlink destination (what target points at)
#
# Fail-loud: these are oneshot systemd services gating NetworkManager.service
# / bluetooth.service startup (Before=), not wrappers around a user command,
# so a missing/unmounted @shared or a failed symlink is a hard error exactly
# as it was before extraction (both original bodies already `exit 1` on
# every failure path).
set -eu

NAME="${1:?shared-symlink: entry name required, e.g. \"shared-symlink networkmanager\"}"
CONFIG_JSON="${SHARED_SYMLINK_CONFIG_JSON:-/etc/cloud-data/shared-symlinks.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t shared-symlink -p user.err "$CONFIG_JSON missing or unreadable"
  exit 1
fi

ENTRY="$(jq -c --arg n "$NAME" '.[] | select(.name == $n)' "$CONFIG_JSON")"
if [ -z "$ENTRY" ]; then
  logger -t shared-symlink -p user.err "no entry named '$NAME' in $CONFIG_JSON"
  exit 1
fi

LABEL="$(printf '%s' "$ENTRY" | jq -r '.label')"
MOUNT_CHECK="$(printf '%s' "$ENTRY" | jq -r '.mount_check')"
DIR_PERM="$(printf '%s' "$ENTRY" | jq -r '.dir_perm')"
TARGET_PARENT="$(printf '%s' "$ENTRY" | jq -r '.target_parent // empty')"
TARGET="$(printf '%s' "$ENTRY" | jq -r '.target')"
SOURCE="$(printf '%s' "$ENTRY" | jq -r '.source')"

echo "[$LABEL] Setting up persistent storage..."

# Check if @shared is mounted
if ! mountpoint -q "$MOUNT_CHECK" 2>/dev/null; then
  echo "[$LABEL] ERROR: $MOUNT_CHECK is not mounted" >&2
  exit 1
fi

# Create @shared directories if needed
while IFS= read -r d; do
  [ -n "$d" ] || continue
  if mkdir -p "$d" 2>/dev/null; then
    chmod "$DIR_PERM" "$d"
  else
    echo "[$LABEL] ERROR: Failed to create directory $d" >&2
    exit 1
  fi
done << CREATEDIRS
$(printf '%s' "$ENTRY" | jq -r '.create_dirs[]')
CREATEDIRS
echo "[$LABEL] Created shared directories"

# Ensure the target's parent directory exists
if [ -n "$TARGET_PARENT" ]; then
  mkdir -p "$TARGET_PARENT"
fi

# Remove any existing target
if [ -e "$TARGET" ]; then
  if rm -rf "$TARGET" 2>/dev/null; then
    echo "[$LABEL] Removed existing $TARGET"
  else
    echo "[$LABEL] WARNING: Could not remove $TARGET" >&2
  fi
fi

# Create symlink
if ln -sf "$SOURCE" "$TARGET"; then
  echo "[$LABEL] SUCCESS: $TARGET -> $SOURCE"
else
  echo "[$LABEL] ERROR: Failed to create symlink" >&2
  exit 1
fi
