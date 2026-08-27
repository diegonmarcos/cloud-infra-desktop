# nix-specs — set up /nix/specs symlink to the config repo (with fallback)
#
# Extracted from configuration_persistence.nix
# (system.activationScripts.nixSpecs). Runtime-data-driven: the repo source
# directory and the /nix/specs target directory are read from
# /etc/cloud-data/nix-specs.json via jq at RUNTIME rather than being baked
# into this activation script by Nix interpolation.
#
# Fail-loud vs fall-through: this runs during system.activationScripts,
# which executes as part of switching generations — a hard `exit 1` here can
# break the generation switch. Mirrors the existing behavior exactly: every
# failure path here already only warns/falls back to a README rather than
# aborting, so this script preserves that and never hard-exits.
set -eu

CONFIG_JSON="${NIX_SPECS_CONFIG_JSON:-/etc/cloud-data/nix-specs.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  echo "[SPECS] WARNING: $CONFIG_JSON missing or unreadable, using built-in defaults" >&2
  SPECS_SRC="/home/diego/git/cloud-infra-desktop/aa_nixos-surface_host"
  SPECS_TARGET="/nix/specs"
else
  SPECS_SRC="$(jq -r '.source_dir' "$CONFIG_JSON")"
  SPECS_TARGET="$(jq -r '.target_dir' "$CONFIG_JSON")"
fi

echo "[SPECS] Setting up $SPECS_TARGET..."

# Check if source exists
if [ -d "$SPECS_SRC" ]; then
  # Remove existing symlink/directory
  if [ -L "$SPECS_TARGET" ]; then
    rm -f "$SPECS_TARGET"
    echo "[SPECS] Removed old symlink"
  elif [ -d "$SPECS_TARGET" ]; then
    rm -rf "$SPECS_TARGET"
    echo "[SPECS] Removed old directory"
  fi

  # Create symlink
  if ln -sf "$SPECS_SRC" "$SPECS_TARGET"; then
    echo "[SPECS] SUCCESS: $SPECS_TARGET -> $SPECS_SRC"

    # Verify symlink works
    if [ -f "$SPECS_TARGET/flake.nix" ]; then
      echo "[SPECS] Verified: flake.nix accessible"
    else
      echo "[SPECS] WARNING: Symlink created but flake.nix not found" >&2
    fi
  else
    echo "[SPECS] ERROR: Failed to create symlink" >&2
  fi
else
  # Source not found — repo path missing or home not mounted yet.
  echo "[SPECS] WARNING: Config source not found at $SPECS_SRC" >&2

  if ! mountpoint -q /home/diego 2>/dev/null; then
    echo "[SPECS] HINT: /home/diego is not mounted (LUKS pool not unlocked?)" >&2
  fi

  # Create fallback directory with README
  mkdir -p "$SPECS_TARGET"
  cat > "$SPECS_TARGET/README.md" << SPECEOF
# NixOS Specs - FALLBACK MODE

Configuration source not found at expected location.

## Expected Location
$SPECS_SRC

## Troubleshooting

1. Check if /home/diego is mounted (it lives on the LUKS btrfs pool):
   mountpoint /home/diego

2. If LUKS is locked, unlock + mount the pool:
   sudo cryptsetup open /dev/nvme0n1p4 pool
   sudo mount -o subvol=@home-diego /dev/mapper/pool /home/diego

3. Rebuild NixOS once the source is reachable:
   sudo nixos-rebuild switch --flake $SPECS_SRC#surface

## Alternative

The system is fully functional without $SPECS_TARGET.
Edit configuration directly at the source location.
SPECEOF
  echo "[SPECS] Created fallback README at $SPECS_TARGET/"
fi
