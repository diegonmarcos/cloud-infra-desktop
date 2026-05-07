#!/bin/sh
# deploy-grub.sh — pure copy of dist/boot/* → /boot/* + run NVRAM apply.
#
# After src/gen/render-*.sh have run, dist/ contains the COMPLETE bootloader
# tree ready to be copied verbatim into the system. This deploy script is
# just rsync-style file copying:
#
#   dist/boot/grub/grub.cfg              →  /boot/grub/grub.cfg
#   dist/boot/grub/x86_64-efi/*.mod      →  /boot/grub/x86_64-efi/
#   dist/boot/grub/fonts/unicode.pf2     →  /boot/grub/fonts/
#   dist/boot/efi/EFI/<vendor>/*.efi     →  /boot/efi/EFI/<vendor>/
#   dist/boot/kernels/<hash>-*           →  /boot/kernels/
#   dist/nvram/apply.sh                  →  efibootmgr commands (NVRAM=1)
#
# Multi-OS: works from any of the 4 OSes that mounts /boot and /boot/efi.
# Refuses if mounted partitions don't match the expected UUIDs in boot.json.
#
# Env:
#   BOOT_DIR / ESP_DIR        auto-detected via UUID match
#   YES=1                     skip interactive confirm
#   DRY_RUN=1                 show what would happen, write nothing
#   NVRAM=1                   run dist/nvram/apply.sh
#   SKIP_KERNELS=1            skip /boot/kernels copy (faster re-deploy)
#   SKIP_GRUB_BIN=1           skip GRUB modules + grubx64.efi copy

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# shellcheck source=lib/log.sh
. "$ROOT_DIR/src/engine/lib/log.sh"

BOOT_JSON="$ROOT_DIR/src/boot.json"
EXPECTED_BOOT_UUID=$(jq -r '.uefi.boot.uuid' "$BOOT_JSON")
EXPECTED_ESP_UUID=$(jq -r '.uefi.esp.uuid' "$BOOT_JSON")
EFI_INSTALL_DIR=$(jq -r '.grub.install.efi_install_dir // "/EFI/bootloader"' "$BOOT_JSON")

# Engine policy from boot.json (env-var still overrides for ad-hoc / CI)
: "${YES:=$(jq -r 'if (.engine.interactive // false) then "0" else "1" end' "$BOOT_JSON")}"
: "${DRY_RUN:=$(jq -r 'if (.engine.dry_run // false) then "1" else "0" end' "$BOOT_JSON")}"
: "${SKIP_KERNELS:=$(jq -r 'if (.engine.grub_install.include_kernels // true) then "0" else "1" end' "$BOOT_JSON")}"
: "${SKIP_GRUB_BIN:=$(jq -r 'if (.engine.grub_install.include_binaries // true) then "0" else "1" end' "$BOOT_JSON")}"
export YES DRY_RUN SKIP_KERNELS SKIP_GRUB_BIN

DIST_BOOT="$ROOT_DIR/dist/boot"
DIST_NVRAM="$ROOT_DIR/dist/nvram"

# ── Auto-detect mountpoints by UUID ────────────────────────────────────────

detect_by_uuid() {
    expected="$1"; cands="$2"
    for c in $cands; do
        [ -d "$c" ] || continue
        actual=$(findmnt -n -o UUID --target "$c" 2>/dev/null || echo "")
        if [ "$actual" = "$expected" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

BOOT_DIR=$(detect_by_uuid "$EXPECTED_BOOT_UUID" "${BOOT_DIR:-} /boot /run/media/diego/boot /run/media/$USER/boot /mnt/boot") || {
    error "Could not find /boot with UUID $EXPECTED_BOOT_UUID"
    error "Set BOOT_DIR explicitly to the correct mountpoint."
    exit 1
}

ESP_DIR=$(detect_by_uuid "$EXPECTED_ESP_UUID" "${ESP_DIR:-} /boot/efi /mnt/efi /run/media/$USER/efi") || {
    warn "ESP with UUID $EXPECTED_ESP_UUID not mounted — ESP-related steps will skip"
    ESP_DIR=""
}

# ── Sanity ─────────────────────────────────────────────────────────────────

[ -d "$DIST_BOOT" ] || { error "Missing $DIST_BOOT — run: ./build.sh generate"; exit 1; }
[ -f "$DIST_BOOT/grub/grub.cfg" ] || { error "Missing $DIST_BOOT/grub/grub.cfg"; exit 1; }

header "deploy-grub.sh"
log "BOOT_DIR:  $BOOT_DIR (UUID $EXPECTED_BOOT_UUID)"
log "ESP_DIR:   ${ESP_DIR:-<unmounted>} (UUID $EXPECTED_ESP_UUID)"
log "DRY_RUN:   ${DRY_RUN:-0}"

# ── Plan ───────────────────────────────────────────────────────────────────

if [ -f "$BOOT_DIR/grub/grub.cfg" ] && cmp -s "$DIST_BOOT/grub/grub.cfg" "$BOOT_DIR/grub/grub.cfg"; then
    log "  grub.cfg:    in sync"
else
    log "  grub.cfg:    will overwrite"
fi
if [ "${SKIP_GRUB_BIN:-0}" != "1" ]; then
    [ -d "$DIST_BOOT/grub/x86_64-efi" ] && log "  GRUB mods:   $(ls "$DIST_BOOT/grub/x86_64-efi" 2>/dev/null | wc -l) files → $BOOT_DIR/grub/x86_64-efi/"
    [ -f "$DIST_BOOT/grub/fonts/unicode.pf2" ] && log "  font:        → $BOOT_DIR/grub/fonts/unicode.pf2"
    [ -n "$ESP_DIR" ] && [ -f "$DIST_BOOT/efi$EFI_INSTALL_DIR/grubx64.efi" ] && log "  grubx64.efi: → $ESP_DIR$EFI_INSTALL_DIR/grubx64.efi"
fi
[ "${SKIP_KERNELS:-0}" != "1" ] && [ -d "$DIST_BOOT/kernels" ] && log "  kernels:     $(ls "$DIST_BOOT/kernels" 2>/dev/null | wc -l) files → $BOOT_DIR/kernels/"
[ "${NVRAM:-0}" = "1" ] && [ -x "$DIST_NVRAM/apply.sh" ] && log "  NVRAM:       run $DIST_NVRAM/apply.sh"

if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN=1 — exiting before any write"
    exit 0
fi

if [ "${YES:-0}" != "1" ]; then
    printf "${BOLD}Proceed? [y/N]:${NC} "
    read -r ans
    case "$ans" in y|Y) ;; *) warn "Aborted"; exit 1 ;; esac
fi

[ "$(id -u)" -eq 0 ] || { error "Must run as root"; exit 1; }

# ── Apply: pure copy ───────────────────────────────────────────────────────

# 1. grub.cfg (with backup)
TARGET_CFG="$BOOT_DIR/grub/grub.cfg"
BACKUPS_DIR="$BOOT_DIR/grub/.aa_bootloader-backups"
if [ ! -f "$TARGET_CFG" ] || ! cmp -s "$DIST_BOOT/grub/grub.cfg" "$TARGET_CFG"; then
    mkdir -p "$BACKUPS_DIR"
    [ -f "$TARGET_CFG" ] && cp -a "$TARGET_CFG" "$BACKUPS_DIR/grub.cfg.$(date +%Y%m%d-%H%M%S)" || true
    cp -a "$DIST_BOOT/grub/grub.cfg" "$TARGET_CFG"
    log "wrote $TARGET_CFG"
fi

# 2. GRUB modules + font
if [ "${SKIP_GRUB_BIN:-0}" != "1" ]; then
    if [ -d "$DIST_BOOT/grub/x86_64-efi" ]; then
        mkdir -p "$BOOT_DIR/grub/x86_64-efi"
        cp -af "$DIST_BOOT/grub/x86_64-efi/." "$BOOT_DIR/grub/x86_64-efi/"
        log "wrote $(ls "$BOOT_DIR/grub/x86_64-efi" | wc -l) modules → $BOOT_DIR/grub/x86_64-efi/"
    fi
    if [ -f "$DIST_BOOT/grub/fonts/unicode.pf2" ]; then
        mkdir -p "$BOOT_DIR/grub/fonts"
        cp -af "$DIST_BOOT/grub/fonts/unicode.pf2" "$BOOT_DIR/grub/fonts/"
        log "wrote $BOOT_DIR/grub/fonts/unicode.pf2"
    fi

    # 3. grubx64.efi → ESP
    # vfat doesn't support unix ownership; cp -a fails on chown step. Use
    # --no-preserve=ownership (matches install-refind.sh's pattern). Fall
    # back to plain cp -f if --no-preserve isn't available (BSD cp).
    if [ -n "$ESP_DIR" ] && [ -f "$DIST_BOOT/efi$EFI_INSTALL_DIR/grubx64.efi" ]; then
        mkdir -p "$ESP_DIR$EFI_INSTALL_DIR"
        cp -f --no-preserve=ownership "$DIST_BOOT/efi$EFI_INSTALL_DIR/grubx64.efi" "$ESP_DIR$EFI_INSTALL_DIR/grubx64.efi" 2>/dev/null || \
            cp -f "$DIST_BOOT/efi$EFI_INSTALL_DIR/grubx64.efi" "$ESP_DIR$EFI_INSTALL_DIR/grubx64.efi"
        log "wrote $ESP_DIR$EFI_INSTALL_DIR/grubx64.efi"
    fi
fi

# 4. kernels + initrds
if [ "${SKIP_KERNELS:-0}" != "1" ] && [ -d "$DIST_BOOT/kernels" ]; then
    mkdir -p "$BOOT_DIR/kernels"
    cp -af "$DIST_BOOT/kernels/." "$BOOT_DIR/kernels/"
    log "wrote $(ls "$BOOT_DIR/kernels" | wc -l) kernel/initrd files → $BOOT_DIR/kernels/"
fi

# Flush dirty pages — use POSIX-default PATH so we don't pick up user-shadowed
# `sync` shims (e.g. /home/diego/.nix-profile/bin/sync that points at a
# missing script). Best-effort; tolerate failure rather than abort the install.
command -p sync 2>/dev/null || /bin/sync 2>/dev/null || true

# 5. NVRAM
if [ "${NVRAM:-0}" = "1" ] && [ -x "$DIST_NVRAM/apply.sh" ]; then
    log "running NVRAM apply..."
    sh "$DIST_NVRAM/apply.sh"
fi

log "deploy-grub: complete"
