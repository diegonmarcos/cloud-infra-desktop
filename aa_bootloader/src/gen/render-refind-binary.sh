#!/bin/sh
# render-refind-binary.sh — copy vendored rEFInd binaries into dist/
#
# Source: src/vendored/refind-<version>/  (committed binaries from upstream
# https://sourceforge.net/projects/refind/, ~1.3 MB total)
# Output:
#   dist/boot/efi/EFI/refind/refind_x64.efi
#   dist/boot/efi/EFI/refind/drivers_x64/{btrfs,ext4,iso9660}_x64.efi
#   dist/boot/efi/EFI/refind/icons/  (cosmetic, optional via JSON)
#
# Multi-OS: works from any OS — no system dependencies, vendored binaries
# are signed-by-upstream EFI binaries that run on any UEFI firmware.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# shellcheck source=lib/log.sh
. "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/json.sh
. "$SCRIPT_DIR/lib/json.sh"

BOOT_JSON="$ROOT_DIR/src/boot.json"
VERSION=$(jq -r '.refind.version // "0.14.2"' "$BOOT_JSON")
INCLUDE_ICONS=$(jq -r '.refind.install.include_icons // true' "$BOOT_JSON")

VENDORED="$ROOT_DIR/src/vendored/refind-$VERSION"
OUT="$ROOT_DIR/dist/boot/efi/EFI/refind"

if [ ! -d "$VENDORED" ]; then
    error "Vendored rEFInd not found: $VENDORED"
    error "Download with:"
    error "  curl -L https://sourceforge.net/projects/refind/files/$VERSION/refind-bin-$VERSION.zip/download -o /tmp/r.zip"
    error "  unzip /tmp/r.zip -d /tmp/r && cp -r /tmp/r/refind-bin-$VERSION/refind/* $VENDORED/"
    exit 1
fi

mkdir -p "$OUT/drivers_x64"

# Main binary
cp -af "$VENDORED/refind_x64.efi" "$OUT/refind_x64.efi"
log "Staged refind_x64.efi ($(stat -c %s "$OUT/refind_x64.efi") bytes)"

# Drivers (per JSON include list)
for drv in $(jq -r '.refind.install.include_drivers[]' "$BOOT_JSON"); do
    src="$VENDORED/drivers_x64/${drv}.efi"
    if [ -f "$src" ]; then
        cp -af "$src" "$OUT/drivers_x64/${drv}.efi"
        log "  driver: ${drv}.efi"
    else
        warn "  missing driver in vendored: ${drv}.efi"
    fi
done

# Sample config (for reference; the real one is rendered separately)
[ -f "$VENDORED/refind.conf-sample" ] && cp -af "$VENDORED/refind.conf-sample" "$OUT/refind.conf-sample"

# Icons (optional)
if [ "$INCLUDE_ICONS" = "true" ] && [ -d "$VENDORED/icons" ]; then
    mkdir -p "$OUT/icons"
    cp -af "$VENDORED/icons/." "$OUT/icons/"
    log "Staged $(ls "$OUT/icons" | wc -l) icons"
fi

log "rEFInd binaries staged: $(du -sh "$OUT" | cut -f1) → $OUT"
