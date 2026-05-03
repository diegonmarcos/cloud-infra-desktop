#!/bin/sh
# deploy-grub.sh — Phase 3 STUB
# Will copy dist/boot/grub/grub.cfg → /boot/grub/grub.cfg and
# dist/boot/efi/EFI/* → /boot/efi/EFI/, plus install grubx64.efi from
# the GRUB package and run dist/nvram/apply.sh.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../gen/lib/log.sh
. "$ROOT_DIR/gen/lib/log.sh"

warn "deploy-grub.sh is a Phase 3 stub — no actions performed."
warn "Phase 1: NixOS still authors /boot/grub/grub.cfg via boot.loader.grub."
warn "Phase 3 will populate this script and yield NixOS authority."
exit 0
