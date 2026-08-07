# pool-witness-stamp-on-mount — stamp a fresh nonce on the pool at mount to
# detect out-of-band mounts between NixOS boots
#
# Extracted from configuration_pool_witness.nix
# (systemd.services."pool-witness-stamp-on-mount".script). Runtime-data-driven:
# the on-pool witness directory is read from
# /etc/cloud-data/pool-witness.json via jq at RUNTIME. RuntimeDirectory=
# pool-witness and StateDirectory=pool-witness (systemd-managed
# /run/pool-witness and /var/lib/pool-witness) stay Nix-side — they're
# systemd unit config, not data this script needs to look up. Real binary
# paths (head, od, sync, logger) arrive via writeShellApplication
# runtimeInputs.
#
# Fail-loud: NO — `set -eu` is retained (any genuinely unexpected error still
# aborts the oneshot, unchanged from before extraction), but the actual
# out-of-band-mount DETECTION is deliberately non-fatal: it only `logger -p
# user.crit`s so the separate hibernate preflight gate
# (configuration_pre-hibernate-warning.nix) can consult the signal and
# refuse hibernation — it must NOT fail this unit and block
# local-fs.target / normal boot. This mirrors the original exactly.
set -eu

CONFIG_JSON="${POOL_WITNESS_CONFIG_JSON:-/etc/cloud-data/pool-witness.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t pool-witness -p user.err "$CONFIG_JSON missing or unreadable"
  exit 1
fi

WITNESS_DIR="$(jq -r '.witness_dir' "$CONFIG_JSON")"

# Boot-time check: previous nonce on disk must match what we last wrote
# at clean shutdown. If mismatched, something else mounted the pool —
# log loudly so the hibernate preflight gate can refuse.
PREV=$(cat "$WITNESS_DIR/id" 2>/dev/null || echo "")
LAST=$(cat /var/lib/pool-witness/last-clean-mount.id 2>/dev/null || echo "")
if [ -n "$LAST" ] && [ -n "$PREV" ] && [ "$PREV" != "$LAST" ]; then
  logger -t pool-witness -p user.crit \
    "POOL MOUNTED OUT-OF-BAND: disk_nonce=$PREV expected=$LAST — hibernate will be refused this boot. Source: another OS or live-USB unlocked LUKS and mounted the pool."
fi

# Stamp this boot.
NEW=$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')
echo "$NEW" > "$WITNESS_DIR/id"
echo "$NEW" > /run/pool-witness/current-mount.id
sync -f "$WITNESS_DIR/id"

logger -t pool-witness -p user.info \
  "stamped nonce=$NEW for this NixOS boot"
