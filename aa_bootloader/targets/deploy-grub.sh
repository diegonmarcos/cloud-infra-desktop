#!/bin/sh
# deploy-grub.sh — aa_bootloader's TOTAL bootloader install.
#
# This is the universal "write /boot" script. It owns:
#   1. /boot/grub/grub.cfg                                ← from dist/
#   2. /boot/grub/x86_64-efi/*.mod (GRUB modules)         ← from grub2_efi package
#   3. /boot/grub/fonts/unicode.pf2                       ← from grub2_efi package
#   4. /boot/efi/EFI/NixOS-boot-efi/grubx64.efi           ← from grub2_efi package
#   5. /boot/kernels/<hash>-bzImage and -initrd           ← walked from /nix/var/nix/profiles/
#   6. NVRAM entries via efibootmgr                       ← from dist/nvram/apply.sh
#
# Replaces NixOS's `grub-install`-driven flow entirely. Run after
# `nixos-rebuild build` (which builds the closure but does NOT write /boot
# when boot.loader.grub.enable=false).
#
# Env:
#   BOOT_DIR              auto-detected via UUID match (defaults: /boot, /run/media/diego/boot)
#   YES=1                 skip interactive confirm
#   DRY_RUN=1             show what would happen, write nothing
#   SKIP_KERNELS=1        skip /boot/kernels copy (faster re-deploy if no new gen)
#   SKIP_GRUB_BIN=1       skip grubx64.efi + modules copy
#   SKIP_NVRAM=1          skip NVRAM efibootmgr step
#   GRUB2_EFI_DRV         override path to grub2_efi package (else found in /nix/store)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../gen/lib/log.sh
. "$ROOT_DIR/gen/lib/log.sh"

BOOT_JSON="$ROOT_DIR/src/boot.json"
EXPECTED_BOOT_UUID=$(jq -r '.uefi.boot.uuid' "$BOOT_JSON")
EXPECTED_ESP_UUID=$(jq -r '.uefi.esp.uuid' "$BOOT_JSON")
EFI_INSTALL_DIR=$(jq -r '.grub.install.efi_install_dir // "/EFI/NixOS-boot-efi"' "$BOOT_JSON")

# ── Auto-detect /boot via UUID match ────────────────────────────────────────

detect_mount_by_uuid() {
    expected_uuid="$1"
    candidates="${2:-} /boot /run/media/diego/boot /run/media/$USER/boot /mnt/boot"
    for c in $candidates; do
        [ -d "$c" ] || continue
        actual=$(findmnt -n -o UUID --target "$c" 2>/dev/null || echo "")
        if [ "$actual" = "$expected_uuid" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

BOOT_DIR=$(detect_mount_by_uuid "$EXPECTED_BOOT_UUID" "${BOOT_DIR:-}") || {
    error "Could not find /boot with UUID $EXPECTED_BOOT_UUID"
    error "Set BOOT_DIR explicitly to the NixOS /boot mountpoint."
    exit 1
}

ESP_DIR=$(detect_mount_by_uuid "$EXPECTED_ESP_UUID" "${ESP_DIR:-} /boot/efi /mnt/efi") || {
    warn "Could not find ESP with UUID $EXPECTED_ESP_UUID"
    warn "ESP-related steps (grubx64.efi copy, NVRAM) will be skipped."
    SKIP_GRUB_BIN=1
    SKIP_NVRAM=1
    ESP_DIR=""
}

DIST_GRUB_CFG="$ROOT_DIR/dist/boot/grub/grub.cfg"
TARGET_CFG="$BOOT_DIR/grub/grub.cfg"
BACKUPS_DIR="$BOOT_DIR/grub/.aa_bootloader-backups"

if [ ! -f "$DIST_GRUB_CFG" ]; then
    error "Missing $DIST_GRUB_CFG — run: ./build.sh generate"
    exit 1
fi

header "deploy-grub.sh"
log "BOOT_DIR:  $BOOT_DIR (UUID $EXPECTED_BOOT_UUID)"
log "ESP_DIR:   ${ESP_DIR:-<none>} (UUID $EXPECTED_ESP_UUID)"
log "DRY_RUN:   ${DRY_RUN:-0}"

# ── 1. /boot/grub/grub.cfg ──────────────────────────────────────────────────

NEEDS_CFG_WRITE=0
if [ ! -f "$TARGET_CFG" ] || ! cmp -s "$DIST_GRUB_CFG" "$TARGET_CFG"; then
    NEEDS_CFG_WRITE=1
    log "grub.cfg: differs (will overwrite)"
else
    log "grub.cfg: in sync, skipping"
fi

# ── 2. Locate grub2_efi package (for binary + modules) ─────────────────────

if [ "${SKIP_GRUB_BIN:-0}" != "1" ]; then
    # Multi-OS GRUB tool discovery — try system $PATH first, then /nix/store
    if [ -n "${GRUB2_EFI_DRV:-}" ]; then
        :
    elif command -v grub-install >/dev/null 2>&1; then
        # System grub package (Kali apt grub-efi-amd64, Arch grub, Fedora grub2-efi)
        GRUB_INSTALL=$(command -v grub-install)
        GRUB_MKIMAGE=$(command -v grub-mkimage 2>/dev/null || command -v grub2-mkimage)
        # Find modules directory — derived from GRUB_INSTALL --version package layout
        for cand in /usr/lib/grub/x86_64-efi /lib/grub/x86_64-efi /boot/grub/x86_64-efi-source; do
            [ -d "$cand" ] && { GRUB_MODULES_DIR="$cand"; break; }
        done
        # Font location varies by distro
        for cand in /usr/share/grub/unicode.pf2 /usr/share/grub2/themes/unicode.pf2 /boot/grub/fonts/unicode.pf2; do
            [ -f "$cand" ] && { GRUB_FONT="$cand"; break; }
        done
        log "GRUB tools: system ($GRUB_INSTALL)"
    elif ls -dt /nix/store/*-grub-2.*/sbin/grub-install 2>/dev/null | head -1 | grep -q .; then
        # Fallback: /nix/store (NixOS-style)
        GRUB2_EFI_DRV=$(ls -dt /nix/store/*-grub-2.*/sbin/grub-install 2>/dev/null | head -1 | sed 's|/sbin/grub-install$||')
        GRUB_INSTALL="$GRUB2_EFI_DRV/sbin/grub-install"
        GRUB_MKIMAGE="$GRUB2_EFI_DRV/bin/grub-mkimage"
        GRUB_MODULES_DIR="$GRUB2_EFI_DRV/lib/grub/x86_64-efi"
        GRUB_FONT="$GRUB2_EFI_DRV/share/grub/unicode.pf2"
        log "GRUB tools: nix store ($GRUB2_EFI_DRV)"
    else
        warn "GRUB tools not found in \$PATH or /nix/store — skipping binary+modules step"
        warn "Install GRUB on this OS: apt install grub-efi-amd64  /  pacman -S grub  /  dnf install grub2-efi-x64"
        SKIP_GRUB_BIN=1
    fi
fi

# ── 3. Locate kernels/initrds via /nix/var/nix/profiles ─────────────────────

NIX_PROFILES="${NIX_PROFILES:-/nix/var/nix/profiles}"
if [ ! -d "$NIX_PROFILES" ]; then
    warn "$NIX_PROFILES not found — skipping kernel/initrd copy"
    SKIP_KERNELS=1
fi

# ── DRY_RUN early exit ─────────────────────────────────────────────────────

if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN=1 — exiting before any write"
    exit 0
fi

# ── Confirm ────────────────────────────────────────────────────────────────

if [ "${YES:-0}" != "1" ]; then
    printf "${BOLD}Proceed with deploy? [y/N]:${NC} "
    read -r ans
    case "$ans" in y|Y) ;; *) warn "Aborted"; exit 1 ;; esac
fi

if [ "$(id -u)" -ne 0 ]; then
    error "Must run as root"
    exit 1
fi

# ── Step 1: write /boot/grub/grub.cfg ───────────────────────────────────────

if [ "$NEEDS_CFG_WRITE" = "1" ]; then
    mkdir -p "$BACKUPS_DIR"
    ts=$(date +%Y%m%d-%H%M%S)
    if [ -f "$TARGET_CFG" ]; then
        cp -a "$TARGET_CFG" "$BACKUPS_DIR/grub.cfg.$ts" || true
        log "Backup: $BACKUPS_DIR/grub.cfg.$ts"
    fi
    cp -a "$DIST_GRUB_CFG" "$TARGET_CFG"
    sync
    log "Wrote: $TARGET_CFG"
fi

# ── Step 2: copy GRUB modules + fonts ──────────────────────────────────────

if [ "${SKIP_GRUB_BIN:-0}" != "1" ]; then
    MODULES_SRC="$GRUB2_EFI_DRV/lib/grub/x86_64-efi"
    MODULES_DST="$BOOT_DIR/grub/x86_64-efi"
    if [ -d "$MODULES_SRC" ]; then
        mkdir -p "$MODULES_DST"
        cp -af "$MODULES_SRC"/. "$MODULES_DST"/
        log "Copied $(ls "$MODULES_DST" | wc -l) GRUB modules → $MODULES_DST"
    else
        warn "GRUB modules source missing: $MODULES_SRC"
    fi

    FONT_SRC="$GRUB2_EFI_DRV/share/grub/unicode.pf2"
    FONT_DST="$BOOT_DIR/grub/fonts/unicode.pf2"
    if [ -f "$FONT_SRC" ]; then
        mkdir -p "$(dirname "$FONT_DST")"
        cp -af "$FONT_SRC" "$FONT_DST"
        log "Copied font → $FONT_DST"
    fi
fi

# ── Step 3: copy grubx64.efi to ESP ────────────────────────────────────────

if [ "${SKIP_GRUB_BIN:-0}" != "1" ] && [ -n "$ESP_DIR" ]; then
    EFI_SRC=""
    for cand in \
        "$GRUB2_EFI_DRV/sbin/grub-install" \
        ; do : ; done
    # The actual grubx64.efi binary needs to be created by grub-mkimage,
    # but on NixOS-built systems the existing /boot/efi/EFI/NixOS-boot-efi/grubx64.efi
    # is already built and signed. Reuse it if present.
    EFI_TARGET_DIR="$ESP_DIR$EFI_INSTALL_DIR"
    EFI_TARGET="$EFI_TARGET_DIR/grubx64.efi"
    if [ -f "$EFI_TARGET" ]; then
        log "grubx64.efi already at $EFI_TARGET (reusing)"
    else
        # Build a fresh one with grub-mkimage (matches what NixOS does)
        if [ -x "$GRUB2_EFI_DRV/bin/grub-mkimage" ]; then
            mkdir -p "$EFI_TARGET_DIR"
            CORE_MODS="part_gpt fat ext2 btrfs luks2 cryptodisk gcry_rijndael gcry_sha256 chain search search_fs_uuid configfile normal linux echo all_video efi_gop efi_uga gfxterm font png"
            "$GRUB2_EFI_DRV/bin/grub-mkimage" -O x86_64-efi \
                -o "$EFI_TARGET" \
                -p "$EFI_INSTALL_DIR" \
                $CORE_MODS
            log "Built fresh grubx64.efi → $EFI_TARGET"
        else
            warn "grub-mkimage missing; can't build grubx64.efi"
        fi
    fi
fi

# ── Step 4: copy kernels + initrds for all generations ─────────────────────

if [ "${SKIP_KERNELS:-0}" != "1" ]; then
    KERNELS_DIR="$BOOT_DIR/kernels"
    mkdir -p "$KERNELS_DIR"

    nix_to_boot_path() {
        target="$1"; name=${target#/nix/store/}
        echo "${name%%/*}-${name##*/}"
    }

    copied=0; existed=0
    for sys_link in "$NIX_PROFILES/system" "$NIX_PROFILES"/system-*-link; do
        [ -e "$sys_link" ] || continue
        sys=$(readlink -f "$sys_link" 2>/dev/null) || continue
        [ -d "$sys" ] || continue

        # default kernel + initrd
        for f in kernel initrd; do
            t=$(readlink "$sys/$f" 2>/dev/null) || continue
            boot_name=$(nix_to_boot_path "$t")
            dst="$KERNELS_DIR/$boot_name"
            if [ -f "$dst" ]; then
                existed=$((existed + 1))
            else
                cp -L "$t" "$dst"
                copied=$((copied + 1))
            fi
        done

        # specialisations
        if [ -d "$sys/specialisation" ]; then
            for spec in "$sys/specialisation"/*; do
                [ -d "$spec" ] || continue
                for f in kernel initrd; do
                    t=$(readlink "$spec/$f" 2>/dev/null) || continue
                    boot_name=$(nix_to_boot_path "$t")
                    dst="$KERNELS_DIR/$boot_name"
                    if [ -f "$dst" ]; then
                        existed=$((existed + 1))
                    else
                        cp -L "$t" "$dst"
                        copied=$((copied + 1))
                    fi
                done
            done
        fi
    done
    sync
    log "Kernels/initrds: $copied copied, $existed already present"
fi

# ── Step 5: NVRAM ──────────────────────────────────────────────────────────

if [ "${SKIP_NVRAM:-0}" != "1" ] && [ -x "$ROOT_DIR/dist/nvram/apply.sh" ]; then
    log "Running NVRAM apply..."
    sh "$ROOT_DIR/dist/nvram/apply.sh"
fi

log "deploy-grub: complete"
