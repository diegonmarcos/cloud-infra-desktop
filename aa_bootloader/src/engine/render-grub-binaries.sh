#!/bin/sh
# render-grub-binaries.sh — stage GRUB binaries into dist/
#
# Copies from whichever GRUB is installed on this OS:
#   - GRUB modules (~280 .mod files) → dist/boot/grub/x86_64-efi/
#   - Unicode font                   → dist/boot/grub/fonts/unicode.pf2
#   - grubx64.efi (built fresh via grub-mkimage with our SoT modules list)
#                                    → dist/boot/efi/EFI/NixOS-boot-efi/grubx64.efi
#
# Multi-OS toolchain discovery:
#   1. system $PATH (Kali apt grub-efi-amd64, Arch grub, Fedora grub2-efi)
#   2. /nix/store (NixOS fallback)
#
# After this runs, deploy-grub.sh is just `cp -a dist/boot/* /boot/` — no
# external dependencies, no late-bound builds at deploy time.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# shellcheck source=lib/log.sh
. "$ROOT_DIR/src/engine/lib/log.sh"
# shellcheck source=lib/json.sh
. "$ROOT_DIR/src/engine/lib/json.sh"

BOOT_JSON="$ROOT_DIR/src/boot.json"
EFI_INSTALL_DIR=$(jq -r '.grub.install.efi_install_dir // "/EFI/NixOS-boot-efi"' "$BOOT_JSON")
CORE_MODS=$(jq -r '.grub.modules | join(" ")' "$BOOT_JSON")

DIST_GRUB="$ROOT_DIR/dist/boot/grub"
DIST_ESP="$ROOT_DIR/dist/boot/efi$EFI_INSTALL_DIR"

# ── Discover GRUB tools ────────────────────────────────────────────────────

if command -v grub-install >/dev/null 2>&1; then
    GRUB_BIN_DIR=$(dirname "$(command -v grub-install)")
    GRUB_MKIMAGE=$(command -v grub-mkimage 2>/dev/null || command -v grub2-mkimage 2>/dev/null || echo "")
    for cand in /usr/lib/grub/x86_64-efi /lib/grub/x86_64-efi /usr/lib/grub2/x86_64-efi; do
        [ -d "$cand" ] && { GRUB_MODULES_DIR="$cand"; break; }
    done
    for cand in /usr/share/grub/unicode.pf2 /usr/share/grub2/themes/unicode.pf2 /usr/share/grub2/unicode.pf2; do
        [ -f "$cand" ] && { GRUB_FONT_SRC="$cand"; break; }
    done
    log "GRUB tools: system ($(command -v grub-install))"
elif ls -dt /nix/store/*-grub-2.*/sbin/grub-install 2>/dev/null | head -1 | grep -q .; then
    GRUB_PKG=$(ls -dt /nix/store/*-grub-2.*/sbin/grub-install 2>/dev/null | head -1 | sed 's|/sbin/grub-install$||')
    GRUB_MKIMAGE="$GRUB_PKG/bin/grub-mkimage"
    GRUB_MODULES_DIR="$GRUB_PKG/lib/grub/x86_64-efi"
    GRUB_FONT_SRC="$GRUB_PKG/share/grub/unicode.pf2"
    log "GRUB tools: nix store ($GRUB_PKG)"
else
    warn "GRUB not found in \$PATH or /nix/store — skipping binary stage"
    warn "Install GRUB: apt install grub-efi-amd64  /  pacman -S grub  /  dnf install grub2-efi-x64"
    exit 0
fi

# ── Stage modules ──────────────────────────────────────────────────────────

if [ -n "${GRUB_MODULES_DIR:-}" ] && [ -d "$GRUB_MODULES_DIR" ]; then
    mkdir -p "$DIST_GRUB/x86_64-efi"
    cp -af "$GRUB_MODULES_DIR"/*.mod "$DIST_GRUB/x86_64-efi/" 2>/dev/null || true
    cp -af "$GRUB_MODULES_DIR"/*.lst "$DIST_GRUB/x86_64-efi/" 2>/dev/null || true
    log "Staged $(ls "$DIST_GRUB/x86_64-efi" | wc -l) GRUB modules → $DIST_GRUB/x86_64-efi/"
else
    warn "GRUB modules dir not found — dist/boot/grub/x86_64-efi/ left empty"
fi

# ── Stage font ─────────────────────────────────────────────────────────────

if [ -n "${GRUB_FONT_SRC:-}" ] && [ -f "$GRUB_FONT_SRC" ]; then
    mkdir -p "$DIST_GRUB/fonts"
    cp -af "$GRUB_FONT_SRC" "$DIST_GRUB/fonts/unicode.pf2"
    log "Staged font → $DIST_GRUB/fonts/unicode.pf2"
fi

# ── Build grubx64.efi (fresh from boot.json's modules list) ────────────────

if [ -n "${GRUB_MKIMAGE:-}" ] && [ -x "$GRUB_MKIMAGE" ]; then
    mkdir -p "$DIST_ESP"
    "$GRUB_MKIMAGE" -O x86_64-efi \
        -o "$DIST_ESP/grubx64.efi" \
        -p "$EFI_INSTALL_DIR" \
        $CORE_MODS
    sz=$(stat -c %s "$DIST_ESP/grubx64.efi" 2>/dev/null || echo "?")
    log "Built grubx64.efi ($sz bytes) → $DIST_ESP/grubx64.efi"
else
    warn "grub-mkimage not found — grubx64.efi NOT staged in dist/"
fi
