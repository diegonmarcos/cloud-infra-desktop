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
. "$ROOT_DIR/src/engine/lib/log.sh"
# shellcheck source=lib/json.sh
. "$ROOT_DIR/src/engine/lib/json.sh"

BOOT_JSON="$ROOT_DIR/src/boot.json"
VERSION=$(jq -r '.refind.version // "0.14.2"' "$BOOT_JSON")
INCLUDE_ICONS=$(jq -r '.refind.install.include_icons // true' "$BOOT_JSON")

VENDORED="$ROOT_DIR/src/loaders/refind/vendored/refind-$VERSION"
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

# Theme (optional, declared in .refind.install.theme)
THEME_ENABLED=$(jq -r '.refind.install.theme.enabled // false' "$BOOT_JSON")
if [ "$THEME_ENABLED" = "true" ]; then
    THEME_NAME=$(jq -r '.refind.install.theme.name' "$BOOT_JSON")
    THEME_PATH=$(jq -r '.refind.install.theme.vendored_path' "$BOOT_JSON")
    THEME_SRC="$ROOT_DIR/src/$THEME_PATH"
    THEME_DST="$OUT/themes/$THEME_NAME"
    if [ -d "$THEME_SRC" ]; then
        mkdir -p "$THEME_DST"
        cp -af "$THEME_SRC/." "$THEME_DST/"
        # Drop docs that don't belong on ESP (LICENSE keeps for attribution).
        rm -f "$THEME_DST/README.md"
        log "Staged theme '$THEME_NAME' → $THEME_DST"
    else
        warn "Theme '$THEME_NAME' enabled but vendored path missing: $THEME_SRC"
    fi
fi

# ── EFI tools (data-driven, FIRE 4) ───────────────────────────────────────
# Stage every entry declared in .refind.tools[] from src/loaders/refind/
# vendored/efi-tools/<source> → dist/.../EFI/refind/tools/<dest>.
TOOLS_SRC="$ROOT_DIR/src/loaders/refind/vendored/efi-tools"
n_tools=$(jq -r '.refind.tools | length // 0' "$BOOT_JSON" 2>/dev/null || echo 0)
if [ "$n_tools" -gt 0 ] && [ -d "$TOOLS_SRC" ]; then
    mkdir -p "$OUT/tools"
    jq -r '.refind.tools[] | [.source, .dest] | @tsv' "$BOOT_JSON" |
        while IFS=$(printf '\t') read -r src dest; do
            if [ -f "$TOOLS_SRC/$src" ]; then
                cp -af "$TOOLS_SRC/$src" "$OUT/tools/$dest"
                log "  tool: $dest ($(stat -c %s "$OUT/tools/$dest") bytes, source=$src)"
            else
                warn "  tool: source $src not in $TOOLS_SRC"
            fi
        done
fi

log "rEFInd binaries staged: $(du -sh "$OUT" | cut -f1) → $OUT"
