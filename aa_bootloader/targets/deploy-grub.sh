#!/bin/sh
# deploy-grub.sh — write dist/boot/grub/grub.cfg → /boot/grub/grub.cfg, run NVRAM apply.
#
# Phase 3: aa_bootloader becomes the bootloader's SoT. This script is the
# universal "write to disk" step: it runs from any OS that has /boot mounted
# and the LUKS pool open (so dist/ is reachable).
#
# Safety:
#   1. Validates target /boot/grub/grub.cfg exists (don't write to wrong path)
#   2. Backs up current grub.cfg before overwriting
#   3. Idempotent: re-running is safe
#
# Env:
#   BOOT_DIR              /boot mountpoint (default: /boot if exists, else /run/media/diego/boot)
#   YES=1                 skip interactive confirmation
#   NVRAM=1               also run dist/nvram/apply.sh
#   DRY_RUN=1             show what would happen, don't write

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../gen/lib/log.sh
. "$ROOT_DIR/gen/lib/log.sh"

BOOT_JSON="$ROOT_DIR/src/boot.json"
EXPECTED_BOOT_UUID=$(jq -r '.uefi.boot.uuid' "$BOOT_JSON")

# Auto-detect /boot: must match the boot.json's expected UUID. Refuse if mismatch.
detect_boot_dir() {
    candidates="${BOOT_DIR:-} /boot /run/media/diego/boot /run/media/$USER/boot"
    for c in $candidates; do
        [ -d "$c/grub" ] || continue
        # Find which device is mounted at $c, get its UUID
        actual_uuid=$(findmnt -n -o UUID --target "$c" 2>/dev/null || echo "")
        if [ "$actual_uuid" = "$EXPECTED_BOOT_UUID" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

BOOT_DIR=$(detect_boot_dir) || {
    error "Could not find /boot with UUID $EXPECTED_BOOT_UUID"
    error "Tried: \$BOOT_DIR=${BOOT_DIR:-unset} /boot /run/media/diego/boot"
    error "Set BOOT_DIR explicitly to the NixOS /boot mountpoint."
    exit 1
}

DIST_GRUB="$ROOT_DIR/dist/boot/grub/grub.cfg"
TARGET_CFG="$BOOT_DIR/grub/grub.cfg"
BACKUPS_DIR="$BOOT_DIR/grub/.aa_bootloader-backups"

if [ ! -f "$DIST_GRUB" ]; then
    error "Missing $DIST_GRUB — run: ./build.sh.new generate"
    exit 1
fi

if [ ! -f "$TARGET_CFG" ]; then
    error "Missing $TARGET_CFG — refusing to write blind"
    error "Confirm BOOT_DIR is correct (currently $BOOT_DIR)"
    exit 1
fi

# Final UUID safety check (paranoia)
ACTUAL_UUID=$(findmnt -n -o UUID --target "$BOOT_DIR" 2>/dev/null || echo "")
if [ "$ACTUAL_UUID" != "$EXPECTED_BOOT_UUID" ]; then
    error "$BOOT_DIR has UUID $ACTUAL_UUID, expected $EXPECTED_BOOT_UUID"
    error "Refusing to write — wrong /boot partition mounted here."
    exit 1
fi

header "deploy-grub.sh"
log "Source:  $DIST_GRUB ($(wc -l < "$DIST_GRUB") lines)"
log "Target:  $TARGET_CFG ($(wc -l < "$TARGET_CFG") lines)"
log "Backup:  $BACKUPS_DIR/"

if cmp -s "$DIST_GRUB" "$TARGET_CFG"; then
    log "Target is already identical to dist/. No-op."
    NEEDS_WRITE=0
else
    NEEDS_WRITE=1
    echo
    echo "Diff (target → dist, first 80 lines):"
    diff -u "$TARGET_CFG" "$DIST_GRUB" | head -80
    echo
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN=1 — exiting before any write"
    exit 0
fi

if [ "$NEEDS_WRITE" = "0" ]; then
    log "Skipping write."
else
    if [ "${YES:-0}" != "1" ]; then
        printf "${BOLD}Overwrite %s? [y/N]:${NC} " "$TARGET_CFG"
        read -r ans
        case "$ans" in
            y|Y) ;;
            *) warn "Aborted"; exit 1 ;;
        esac
    fi

    if [ "$(id -u)" -ne 0 ]; then
        error "Must run as root for /boot writes"
        exit 1
    fi

    mkdir -p "$BACKUPS_DIR"
    ts=$(date +%Y%m%d-%H%M%S)
    cp -a "$TARGET_CFG" "$BACKUPS_DIR/grub.cfg.$ts" || true
    log "Backed up $TARGET_CFG → $BACKUPS_DIR/grub.cfg.$ts"

    cp -a "$DIST_GRUB" "$TARGET_CFG"
    sync
    log "Wrote: $TARGET_CFG"
fi

# NVRAM apply (optional, only if explicitly enabled)
if [ "${NVRAM:-0}" = "1" ]; then
    if [ -x "$ROOT_DIR/dist/nvram/apply.sh" ]; then
        log "Running dist/nvram/apply.sh..."
        if [ "$(id -u)" -ne 0 ]; then
            error "Need root for NVRAM. Re-run with sudo or skip NVRAM=1."
            exit 1
        fi
        sh "$ROOT_DIR/dist/nvram/apply.sh"
    else
        warn "dist/nvram/apply.sh missing — run ./build.sh.new generate"
    fi
else
    log "NVRAM step skipped (set NVRAM=1 to enable)"
fi

log "deploy-grub: done"
