#!/bin/sh
# deploy-nixos.sh — copy dist/adapters/nixos/* into the NixOS flake's modules/
# directory, then optionally run nixos-rebuild.
#
# This script is the ONLY path through which aa_bootloader writes into the
# flake. The flake then owns those files (committed to its own git history)
# but they're regenerated from aa_bootloader/src/ on every deploy.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../gen/lib/log.sh
. "$ROOT_DIR/gen/lib/log.sh"

# ── Configuration ─────────────────────────────────────────────────────────

# The NixOS flake's modules directory. Adjust if the flake moves.
FLAKE_MODULES_DIR="${FLAKE_MODULES_DIR:-$ROOT_DIR/../aa_nixos-surface_host/src/modules}"

# Files we copy from dist/adapters/nixos/ into the flake's modules/.
# Files NOT in this list are ignored even if they exist in dist/.
ADAPTER_FILES="
boot.json
hardware_bootloader_grub.nix
hardware_bootloader_boot.nix
swap_hibernate.nix
"

# Old files that should be removed from the flake (replaced by new ones).
OBSOLETE_FILES="
bootloader_grub.json
bootloader_boot.json
"

# What to run after copying. Empty = just copy, no rebuild.
# Override via: REBUILD_ACTION=boot|switch|test|none ./deploy-nixos.sh
REBUILD_ACTION="${REBUILD_ACTION:-none}"

# ── Pre-flight ────────────────────────────────────────────────────────────

if [ ! -d "$FLAKE_MODULES_DIR" ]; then
    error "Flake modules dir not found: $FLAKE_MODULES_DIR"
    error "Set FLAKE_MODULES_DIR if the flake lives elsewhere."
    exit 1
fi

DIST_NIXOS="$ROOT_DIR/dist/adapters/nixos"
if [ ! -d "$DIST_NIXOS" ]; then
    error "dist/adapters/nixos/ not found. Run: ./build.sh generate"
    exit 1
fi

# ── Plan ──────────────────────────────────────────────────────────────────

header "Deploy → NixOS flake"
log "Source:      $DIST_NIXOS"
log "Destination: $FLAKE_MODULES_DIR"
log "Action:      $REBUILD_ACTION"
echo

echo "Files to be copied:"
for f in $ADAPTER_FILES; do
    src="$DIST_NIXOS/$f"
    dst="$FLAKE_MODULES_DIR/$f"
    if [ ! -f "$src" ]; then
        warn "  SKIP (missing in dist): $f"
        continue
    fi
    if [ -e "$dst" ] && cmp -s "$src" "$dst"; then
        echo "  unchanged   $f"
    elif [ -e "$dst" ]; then
        echo "  UPDATE      $f"
    else
        echo "  NEW         $f"
    fi
done

echo
echo "Files to be removed (obsolete):"
for f in $OBSOLETE_FILES; do
    if [ -e "$FLAKE_MODULES_DIR/$f" ]; then
        echo "  REMOVE      $f"
    else
        echo "  absent      $f"
    fi
done
echo

# ── Confirm ───────────────────────────────────────────────────────────────

if [ "${YES:-0}" != "1" ]; then
    printf "${BOLD}Proceed? [y/N]:${NC} "
    read -r ans
    case "$ans" in
        y|Y) ;;
        *) warn "Aborted"; exit 1 ;;
    esac
fi

# ── Execute ───────────────────────────────────────────────────────────────

for f in $ADAPTER_FILES; do
    src="$DIST_NIXOS/$f"
    dst="$FLAKE_MODULES_DIR/$f"
    [ -f "$src" ] || continue
    cp -f "$src" "$dst"
    log "wrote $dst"
done

for f in $OBSOLETE_FILES; do
    p="$FLAKE_MODULES_DIR/$f"
    if [ -e "$p" ]; then
        rm -f "$p"
        log "removed $p"
    fi
done

# ── Rebuild ───────────────────────────────────────────────────────────────

case "$REBUILD_ACTION" in
    none)
        log "Skipping nixos-rebuild (REBUILD_ACTION=none)"
        log "Run manually:  cd '$FLAKE_MODULES_DIR/..' && sudo nixos-rebuild boot --flake .#surface"
        ;;
    boot|switch|test|dry-build)
        log "Running: nixos-rebuild $REBUILD_ACTION --flake .#surface"
        cd "$FLAKE_MODULES_DIR/.."
        sudo nixos-rebuild "$REBUILD_ACTION" --flake .#surface
        ;;
    *)
        error "Unknown REBUILD_ACTION: $REBUILD_ACTION"
        exit 1
        ;;
esac

log "Deploy complete"
