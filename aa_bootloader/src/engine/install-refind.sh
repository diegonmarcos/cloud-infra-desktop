#!/bin/sh
# deploy-refind.sh — install rEFInd to ESP and add NVRAM entry.
#
# After src/gen/render-refind-* have run, dist/boot/efi/EFI/refind/ contains
# the complete rEFInd install. This script:
#   1. cp -a dist/boot/efi/EFI/refind/* → /boot/efi/EFI/refind/
#   2. efibootmgr --create entry pointing to refind_x64.efi
#      (does NOT modify BootOrder by default — F12 to test first)
#
# Phase 4a (default): rEFInd installed alongside GRUB, default = GRUB unchanged.
# Phase 4b (DEFAULT_BOOT=1): also bumps rEFInd to top of BootOrder.
#
# Env:
#   ESP_DIR             auto-detected via UUID (default /mnt/efi or /boot/efi)
#   YES=1               skip interactive confirm
#   DRY_RUN=1           show plan, write nothing
#   NO_NVRAM=1          skip efibootmgr step (just copy files)
#   DEFAULT_BOOT=1      put rEFInd first in BootOrder

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# shellcheck source=lib/log.sh
. "$ROOT_DIR/src/engine/lib/log.sh"

BOOT_JSON="$ROOT_DIR/src/boot.json"
EXPECTED_ESP_UUID=$(jq -r '.uefi.esp.uuid' "$BOOT_JSON")
ESP_INSTALL_DIR=$(jq -r '.refind.install.esp_dir // "/EFI/refind"' "$BOOT_JSON")
NVRAM_LABEL=$(jq -r '.refind.install.nvram_label // "rEFInd"' "$BOOT_JSON")

# Engine policy from boot.json (env-var still overrides for ad-hoc / CI)
: "${YES:=$(jq -r 'if (.engine.interactive // false) then "0" else "1" end' "$BOOT_JSON")}"
: "${DRY_RUN:=$(jq -r 'if (.engine.dry_run // false) then "1" else "0" end' "$BOOT_JSON")}"
: "${NO_NVRAM:=$(jq -r 'if (.engine.refind_install.manage_nvram // true) then "0" else "1" end' "$BOOT_JSON")}"
: "${DEFAULT_BOOT:=$(jq -r 'if (.engine.refind_install.set_default_boot // true) then "1" else "0" end' "$BOOT_JSON")}"
export YES DRY_RUN NO_NVRAM DEFAULT_BOOT

DIST="$ROOT_DIR/dist/boot/efi$ESP_INSTALL_DIR"

# ── Detect ESP ─────────────────────────────────────────────────────────────

detect_by_uuid() {
    expected="$1"; cands="$2"
    for c in $cands; do
        [ -d "$c" ] || continue
        actual=$(findmnt -n -o UUID --target "$c" 2>/dev/null || echo "")
        [ "$actual" = "$expected" ] && { echo "$c"; return 0; }
    done
    return 1
}

ESP_DIR=$(detect_by_uuid "$EXPECTED_ESP_UUID" "${ESP_DIR:-} /boot/efi /mnt/efi /run/media/$USER/efi") || {
    error "Could not find ESP with UUID $EXPECTED_ESP_UUID"
    exit 1
}

[ -d "$DIST" ] || { error "Missing $DIST — run: ./build.sh generate"; exit 1; }
[ -f "$DIST/refind_x64.efi" ] || { error "Missing refind_x64.efi in dist"; exit 1; }
[ -f "$DIST/refind.conf" ] || { error "Missing refind.conf in dist"; exit 1; }

TARGET="$ESP_DIR$ESP_INSTALL_DIR"

header "deploy-refind.sh"
log "Source:   $DIST"
log "Target:   $TARGET"
log "NVRAM:    $NVRAM_LABEL → \\$(echo "$ESP_INSTALL_DIR/refind_x64.efi" | tr / \\\\)"
log "DRY_RUN:  ${DRY_RUN:-0}"
log "DEFAULT:  ${DEFAULT_BOOT:-0}  (1 = put rEFInd first in BootOrder)"

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

# ── 1. Copy rEFInd tree to ESP ─────────────────────────────────────────────

mkdir -p "$TARGET"
# vfat doesn't support unix ownership; cp -a's chown step warns but file
# content copies fine. Suppress those warnings (file content already there).
cp -rf --no-preserve=ownership "$DIST/." "$TARGET/" 2>/dev/null || \
    cp -rf "$DIST/." "$TARGET/" 2>/dev/null || true
# POSIX-default PATH so we bypass user-shadowed `sync` shims (best-effort).
command -p sync 2>/dev/null || /bin/sync 2>/dev/null || true
log "Copied $(find "$TARGET" -type f | wc -l) files → $TARGET"

# ── 2. NVRAM entry ─────────────────────────────────────────────────────────

if [ "${NO_NVRAM:-0}" = "1" ]; then
    log "NO_NVRAM=1 — skipping efibootmgr"
    log "deploy-refind: complete (NVRAM unchanged)"
    exit 0
fi

if [ ! -d /sys/firmware/efi ]; then
    warn "Not booted via UEFI — skipping NVRAM step"
    exit 0
fi

# ── efibootmgr resolution ────────────────────────────────────────────────
# NixOS hosts may not expose efibootmgr on PATH (it's only installed if listed
# in environment.systemPackages). Look in standard locations, then fall back
# to nix-build for a one-shot fetch from <nixpkgs>. FIRE RULE 4: this resolution
# logic is data-free; the binary itself is the data. Once added to the host
# flake's systemPackages, the first branch hits and the rest is dead code.
if command -v efibootmgr >/dev/null 2>&1; then
    EFIBOOTMGR=$(command -v efibootmgr)
elif [ -x /run/current-system/sw/bin/efibootmgr ]; then
    EFIBOOTMGR=/run/current-system/sw/bin/efibootmgr
elif [ -x /usr/sbin/efibootmgr ]; then
    EFIBOOTMGR=/usr/sbin/efibootmgr
elif [ -x /sbin/efibootmgr ]; then
    EFIBOOTMGR=/sbin/efibootmgr
else
    # Nix store fallback — build (or reuse) efibootmgr from <nixpkgs>.
    EFIBOOTMGR=$(find /nix/store -maxdepth 3 -path '*efibootmgr*/bin/efibootmgr' -type f 2>/dev/null | head -1)
    if [ -z "$EFIBOOTMGR" ] && command -v nix-build >/dev/null 2>&1; then
        out=$(nix-build --no-out-link '<nixpkgs>' -A efibootmgr 2>/dev/null) && \
            EFIBOOTMGR="$out/bin/efibootmgr"
    fi
fi
if [ -z "${EFIBOOTMGR:-}" ] || [ ! -x "$EFIBOOTMGR" ]; then
    error "efibootmgr not found on PATH, /usr/sbin, /sbin, or /nix/store."
    error "Install it via the host flake's environment.systemPackages, or"
    error "set NO_NVRAM=1 to skip the NVRAM step (rEFInd files are already deployed)."
    exit 1
fi
log "efibootmgr: $EFIBOOTMGR"

# Find existing rEFInd entry by name
existing_id=$("$EFIBOOTMGR" | awk -v n="$NVRAM_LABEL" '
    $0 ~ "^Boot[0-9A-Fa-f]+\\* "n"([ \t]|$)" {
        sub("^Boot",""); sub("[*\t ].*",""); print; exit
    }')

# rEFInd EFI path with backslash separators
EFI_PATH=$(echo "$ESP_INSTALL_DIR/refind_x64.efi" | tr / \\\\)

# Detect ESP disk + partition number
ESP_SOURCE=$(findmnt -n -o SOURCE --target "$ESP_DIR")  # /dev/nvme0n1p1
DISK=$(echo "$ESP_SOURCE" | sed 's/p[0-9]*$//')          # /dev/nvme0n1
PART=$(echo "$ESP_SOURCE" | grep -oE '[0-9]+$')          # 1

# Snapshot BootOrder BEFORE any mutation so we can restore exactly
order_before=$("$EFIBOOTMGR" | awk '/^BootOrder:/ {print $2}')

if [ -n "$existing_id" ]; then
    log "rEFInd NVRAM entry already exists: Boot$existing_id"
else
    "$EFIBOOTMGR" -c -d "$DISK" -p "$PART" -L "$NVRAM_LABEL" -l "$EFI_PATH" >/dev/null
    existing_id=$("$EFIBOOTMGR" | awk -v n="$NVRAM_LABEL" '
        $0 ~ "Boot[0-9A-Fa-f]+\\* "n"$" || $0 ~ "Boot[0-9A-Fa-f]+\\* "n" " {
            sub("Boot",""); sub("\\*.*",""); print; exit
        }')
    log "Created NVRAM entry Boot$existing_id ($NVRAM_LABEL → $EFI_PATH)"

    # NOTE: efibootmgr -c auto-prepends new entry to BootOrder. We restore
    # the previous BootOrder unless DEFAULT_BOOT=1 was set.
    if [ "${DEFAULT_BOOT:-0}" != "1" ]; then
        # Append rEFInd to the END of the previous BootOrder (so it's known
        # to firmware but not first).
        new_order="${order_before},${existing_id}"
        "$EFIBOOTMGR" -o "$new_order" >/dev/null
        log "BootOrder restored: $new_order  (rEFInd appended at end)"
    fi
fi

# Optional: set rEFInd first in BootOrder
if [ "${DEFAULT_BOOT:-0}" = "1" ]; then
    cur_order=$("$EFIBOOTMGR" | awk '/^BootOrder:/ {print $2}')
    new_order=$(echo "$cur_order" | tr ',' '\n' | grep -v "^${existing_id}\$" | paste -sd, -)
    new_order="${existing_id},${new_order}"
    "$EFIBOOTMGR" -o "$new_order" >/dev/null
    log "BootOrder bumped: rEFInd is now default ($new_order)"
fi

log "deploy-refind: complete"
echo ""
log "  test:     reboot, hit F12 at firmware → choose '$NVRAM_LABEL'"
log "  promote:  re-run as: DEFAULT_BOOT=1 ./build.sh deploy --target refind"
log "  rollback: sudo efibootmgr -B -b $existing_id  (removes the NVRAM entry)"
