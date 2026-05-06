#!/bin/sh
# deploy-debian.sh — Phase 2 STUB
# Will copy dist/adapters/debian/etc/* into /etc/ on a Debian-family chroot
# (Kali, rescue-os-debian, etc.), disable Debian's grub.d auto-generation,
# run update-initramfs.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

# shellcheck source=../gen/lib/log.sh
. "$ROOT_DIR/src/engine/lib/log.sh"

warn "deploy-debian.sh is a Phase 2 stub — no actions performed."
warn "When implemented, will:"
warn "  - copy dist/adapters/debian/etc/* to /etc/"
warn "  - chmod -x /etc/grub.d/{10_linux,30_os-prober,40_custom}"
warn "  - run update-initramfs -u"
exit 0
