# kernel-closure-backup — mirror the current kernel+initrd (+optionally full
# toplevel) closure to the on-/boot binary cache
#
# Extracted from configuration_kernel_preservation.nix (kernelClosureBackup
# writeShellApplication / systemd.services."kernel-closure-preservation"
# ExecStart). Runtime-data-driven: cache dir, capacity floor and the list of
# store paths to mirror are read from
# /etc/cloud-data/kernel-closure-preservation.json via jq at RUNTIME. Real
# binary paths (nix) arrive via writeShellApplication runtimeInputs.
#
# Fail-loud ONLY on the capacity gate: this backs up onto a 2 GiB /boot that
# must NEVER fill (see module header, "CAPACITY / NEVER FILL"). Refusing loud
# with exit 1 there is intentional and unchanged from before extraction — a
# silent skip would let /boot fill silently. Every individual `nix copy` of a
# preserved path stays non-fatal (`|| true`), exactly as before: one
# unreachable/already-copied path must not abort backing up the rest.
set -eu

CONFIG_JSON="${KERNEL_CLOSURE_CONFIG_JSON:-/etc/cloud-data/kernel-closure-preservation.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t kernel-closure-backup -p user.err "$CONFIG_JSON missing or unreadable"
  exit 1
fi

CACHE="$(jq -r '.cache' "$CONFIG_JSON")"
MIN_FREE_MIB="$(jq -r '.min_free_mib' "$CONFIG_JSON")"

mkdir -p "$CACHE"

# ── Capacity gate ────────────────────────────────────────────────────
FREE_MIB=$(df -BM --output=avail /boot | tail -1 | tr -d 'M ')
if [ "$FREE_MIB" -lt "$MIN_FREE_MIB" ]; then
  # NOTE: no backticks in this message — inside double quotes they are
  # command substitution and would EXECUTE kernel-closure-prune.
  logger -t kernel-closure-backup -p user.crit \
    "REFUSED: /boot free=$FREE_MIB MiB < min=$MIN_FREE_MIB MiB. \
Run 'kernel-closure-prune' or grow /boot (Phase 2)."
  exit 1
fi

echo "[kernel-closure-backup] mirroring current kernel+initrd closure to $CACHE"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  nix --extra-experimental-features 'nix-command flakes' \
    copy --no-check-sigs \
    --to "file://$CACHE?compression=zstd" \
    "$p" || true
done << PRESERVEDPATHS
$(jq -r '.preserved_paths[]' "$CONFIG_JSON")
PRESERVEDPATHS

echo "[kernel-closure-backup] cache size now:"
du -sh "$CACHE" || true
