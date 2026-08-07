# kernel-closure-restore — copy the on-/boot kernel closure cache into a
# target nix store
#
# Extracted from configuration_kernel_preservation.nix (kernelClosureRestore
# writeShellApplication). Runtime-data-driven: the cache directory is read
# from /etc/cloud-data/kernel-closure-preservation.json via jq at RUNTIME
# rather than Nix-interpolated into this body. Real binary paths (nix) arrive
# via writeShellApplication runtimeInputs — never as ${pkgs.foo} strings here.
#
# Usage: kernel-closure-restore [target-nix-dir]  (default: /mnt/nixos/nix)
#
# Fail-loud: this is a manual recovery CLI run from a rescue OS, not a
# background unit — every failure path already `exit 1`'d before extraction,
# preserved as-is (a silent no-op here would strand the operator mid-recovery
# with no diagnostic).
set -eu

CONFIG_JSON="${KERNEL_CLOSURE_CONFIG_JSON:-/etc/cloud-data/kernel-closure-preservation.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t kernel-closure-restore -p user.err "$CONFIG_JSON missing or unreadable"
  exit 1
fi

CACHE="$(jq -r '.cache' "$CONFIG_JSON")"
TARGET_NIX="${1:-/mnt/nixos/nix}"

if [ ! -d "$CACHE" ]; then
  echo "ERROR: kernel closure cache not found at $CACHE" >&2
  echo "Was /boot mounted? Was a NixOS rebuild ever run on this host?" >&2
  exit 1
fi

if [ ! -d "$TARGET_NIX/store" ] && [ "$TARGET_NIX" != "/nix" ]; then
  echo "ERROR: target store $TARGET_NIX/store does not exist" >&2
  echo "Mount the target nix store first (e.g. mount @nixos/nix at $TARGET_NIX)" >&2
  exit 1
fi

echo "[kernel-closure-restore] importing from $CACHE → $TARGET_NIX"
nix --extra-experimental-features 'nix-command flakes' \
  copy \
  --no-check-sigs \
  --from "file://$CACHE" \
  --to "local?root=$TARGET_NIX&store=/nix/store" \
  --all
echo "[kernel-closure-restore] done. Next nixos-install/rebuild reuses the cached kernel instead of rebuilding from source."
