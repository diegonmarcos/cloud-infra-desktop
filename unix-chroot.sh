#!/bin/sh
# unix-chroot.sh — universal multi-OS chroot helper for the Surface Pro 8 box.
#
# Detects which OS you're currently running on and chroots into another OS on
# the same disk. Auto-mounts everything needed (target rootfs, /nix store if
# entering NixOS, kernel filesystems, /etc shims so package managers work).
#
# Usage:
#   sudo ./unix-chroot.sh nixos          enter NixOS @nixos subvolume
#   sudo ./unix-chroot.sh kali           enter Kali (p7 / kali-root)
#   sudo ./unix-chroot.sh debian         enter Debian (p6 / 'debian' label)
#   sudo ./unix-chroot.sh --unmount X    tear down a previously-set chroot
#   sudo ./unix-chroot.sh --status       show all currently-set chroots
#
# Common reasons to chroot:
#   - Run nixos-rebuild from Kali (when NixOS won't boot)
#   - apt update Kali from NixOS
#   - Restore a fucked /etc on either OS
#   - Pin kernel/initrd updates without booting that OS
#
# Required state:
#   - LUKS pool unlocked (cryptsetup open /dev/nvme0n1p4 luks-...)
#   - The target partition NOT currently mounted as an OS (don't chroot to your
#     own running OS)

set -eu

POOL_MOUNT="${POOL_MOUNT:-/run/media/diego/pool}"
LUKS_DEVICE="/dev/mapper/luks-3c75c6db-4d7c-4570-81f1-02d168781aac"

# UUIDs from aa_bootloader/src/boot.json (Surface Pro 8 layout)
KALI_UUID="509491e4-d3a7-426d-9b78-4b024b24cc32"
DEBIAN_UUID="42ccd674-d035-497d-b0eb-bffa28c5144c"
ESP_UUID="2CE0-6722"
BOOT_UUID="0eaf7961-48c5-4b55-8a8f-04cd0b71de07"

# ─── Helpers ────────────────────────────────────────────────────────────────

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
log()   { printf "${G}[%s]${N} %s\n" "$(date '+%H:%M:%S')" "$1"; }
warn()  { printf "${Y}[%s]${N} %s\n" "$(date '+%H:%M:%S')" "$1" >&2; }
error() { printf "${R}[%s]${N} %s\n" "$(date '+%H:%M:%S')" "$1" >&2; }
header() { printf "\n${C}══════════════════════════════════════════════════${N}\n${B}%s${N}\n${C}══════════════════════════════════════════════════${N}\n" "$1"; }

require_root() {
    [ "$(id -u)" -eq 0 ] || { error "Must run as root"; exit 1; }
}

detect_current_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}" in
            nixos)  echo "nixos" ;;
            kali)   echo "kali" ;;
            debian) echo "debian" ;;
            *)      echo "${ID:-unknown}" ;;
        esac
    else
        echo "unknown"
    fi
}

ensure_pool_mounted() {
    if ! mountpoint -q "$POOL_MOUNT" 2>/dev/null; then
        if [ ! -b "$LUKS_DEVICE" ]; then
            error "LUKS pool not open. Run:"
            error "  sudo cryptsetup open /dev/disk/by-uuid/3c75c6db-4d7c-4570-81f1-02d168781aac luks-3c75c6db-4d7c-4570-81f1-02d168781aac"
            exit 1
        fi
        mkdir -p "$POOL_MOUNT"
        mount "$LUKS_DEVICE" "$POOL_MOUNT" || { error "mount $LUKS_DEVICE failed"; exit 1; }
        log "Mounted LUKS pool → $POOL_MOUNT"
    fi
}

# ─── Setup chroot mounts ────────────────────────────────────────────────────

# Bind mount sources A B (from→to). Idempotent.
bind_mount() {
    src="$1"; dst="$2"
    [ -e "$dst" ] || mkdir -p "$dst"
    if mountpoint -q "$dst" 2>/dev/null; then
        return 0
    fi
    mount --bind "$src" "$dst" 2>/dev/null && log "  bind: $src → $dst" || warn "  bind FAIL: $src → $dst"
}

# Common kernel filesystems for any chroot
mount_kernel_fs() {
    target="$1"
    mountpoint -q "$target/proc" || { mkdir -p "$target/proc"; mount -t proc proc "$target/proc" && log "  proc"; }
    mountpoint -q "$target/sys"  || { mkdir -p "$target/sys";  mount --rbind /sys "$target/sys" && mount --make-rslave "$target/sys" && log "  sys (rbind)"; }
    mountpoint -q "$target/dev"  || { mkdir -p "$target/dev";  mount --rbind /dev "$target/dev" && mount --make-rslave "$target/dev" && log "  dev (rbind)"; }
    mountpoint -q "$target/tmp"  || { mkdir -p "$target/tmp";  mount -t tmpfs tmpfs "$target/tmp" && log "  tmp"; }
}

# DNS + hosts so package mgrs work
mount_etc_shims() {
    target="$1"
    [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "$target/etc/resolv.conf" 2>/dev/null && log "  /etc/resolv.conf"
    [ -f /etc/hosts ] && cp /etc/hosts "$target/etc/hosts" 2>/dev/null || true
}

# ─── Per-OS chroot setup ────────────────────────────────────────────────────

setup_nixos() {
    target="${CHROOT_DIR:-/tmp/nixos-chroot}"
    header "Setting up NixOS chroot at $target"
    ensure_pool_mounted

    mkdir -p "$target"
    bind_mount "$POOL_MOUNT/@nixos"      "$target"
    bind_mount "$POOL_MOUNT/@nixos/nix"  "$target/nix"
    bind_mount "$POOL_MOUNT/@home-diego" "$target/home/diego"
    mount_kernel_fs "$target"
    mount_etc_shims "$target"

    # Resolve nix tools from store
    nixbin=$(ls -d "$target"/nix/store/*-nix-2.*/bin 2>/dev/null | grep -v -E '(doc|man|dev)' | head -1 | sed "s|^$target||")
    coreutils=$(ls -d "$target"/nix/store/*-coreutils-*/bin 2>/dev/null | grep -v -E '\.dev|\.bin/$' | head -1 | sed "s|^$target||")
    bashbin=$(ls -d "$target"/nix/store/*-bash-5.*/bin/bash 2>/dev/null | head -1 | sed "s|^$target||")
    git=$(ls -d "$target"/nix/store/*-git-minimal-*/bin 2>/dev/null | head -1 | sed "s|^$target||")
    nixos_rebuild=$(ls -d "$target"/nix/store/*-nixos-rebuild/bin 2>/dev/null | head -1 | sed "s|^$target||")

    # Make /bin/sh and /bin/bash work
    [ -n "$bashbin" ] && ln -sf "$bashbin" "$target/bin/sh" && ln -sf "$bashbin" "$target/bin/bash" && log "  /bin/{sh,bash} → $bashbin"

    # /etc/profile sets PATH so nix/coreutils/git/nixos-rebuild are reachable
    cat > "$target/etc/profile" <<EOF
export PATH="$nixbin:$coreutils:$git:$nixos_rebuild:\$PATH"
export NIX_CONFIG="experimental-features = nix-command flakes"
export HOME=/root
export TERM=\${TERM:-xterm}
EOF

    log "Ready. Enter with:"
    log "  sudo chroot $target /bin/bash --login"
    log "Then: cd /home/diego/git/cloud-infra-desktop/aa_desk-usr_x86_surface-linux_nixos/src && nixos-rebuild boot --flake .#surface"
}

setup_kali() {
    target="${CHROOT_DIR:-/tmp/kali-chroot}"
    kali_dev="/dev/disk/by-uuid/$KALI_UUID"

    header "Setting up Kali chroot at $target"
    [ -b "$kali_dev" ] || { error "Kali partition not found at $kali_dev"; exit 1; }

    mkdir -p "$target"
    if ! mountpoint -q "$target"; then
        mount "$kali_dev" "$target" && log "  Kali root → $target"
    fi
    mount_kernel_fs "$target"
    mount_etc_shims "$target"

    # /home/diego from pool (so git/cloud-vault accessible)
    ensure_pool_mounted
    bind_mount "$POOL_MOUNT/@home-diego" "$target/home/diego"

    log "Ready. Enter with:"
    log "  sudo chroot $target /bin/bash --login"
    log "Then: apt update && apt full-upgrade  (or whatever you needed Kali for)"
}

setup_debian() {
    target="${CHROOT_DIR:-/tmp/debian-chroot}"
    debian_dev="/dev/disk/by-uuid/$DEBIAN_UUID"

    header "Setting up Debian chroot at $target"
    [ -b "$debian_dev" ] || { error "Debian partition not found at $debian_dev"; exit 1; }

    mkdir -p "$target"
    if ! mountpoint -q "$target"; then
        mount "$debian_dev" "$target" && log "  Debian root → $target"
    fi
    mount_kernel_fs "$target"
    mount_etc_shims "$target"

    ensure_pool_mounted
    bind_mount "$POOL_MOUNT/@home-diego" "$target/home/diego"

    log "Ready. Enter with:"
    log "  sudo chroot $target /bin/bash --login"
}

# ─── Unmount ────────────────────────────────────────────────────────────────

do_unmount() {
    os="$1"
    case "$os" in
        nixos)  target="${CHROOT_DIR:-/tmp/nixos-chroot}"  ;;
        kali)   target="${CHROOT_DIR:-/tmp/kali-chroot}"   ;;
        debian) target="${CHROOT_DIR:-/tmp/debian-chroot}" ;;
        *) error "Unknown OS: $os"; exit 1 ;;
    esac
    [ -d "$target" ] || { warn "$target does not exist"; exit 0; }

    header "Unmounting $os chroot at $target"
    # Reverse order, lazy as fallback
    for mnt in "$target/dev/pts" "$target/dev/shm" "$target/dev" "$target/sys" "$target/proc" \
               "$target/tmp" "$target/home/diego" "$target/nix" "$target"; do
        if mountpoint -q "$mnt" 2>/dev/null; then
            umount -R "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null
            log "  umount $mnt"
        fi
    done
    log "Done."
}

# ─── Status ─────────────────────────────────────────────────────────────────

do_status() {
    header "Chroot status"
    log "Current OS: $(detect_current_os)"
    log "LUKS pool:  $(mountpoint -q "$POOL_MOUNT" && echo OPEN || echo closed) ($POOL_MOUNT)"
    echo ""
    for os in nixos kali debian; do
        target=/tmp/$os-chroot
        if [ -d "$target" ] && mountpoint -q "$target" 2>/dev/null; then
            sub=$(mount | grep -c "$target")
            printf "  ${G}●${N} %s — %d mounts at %s\n" "$os" "$sub" "$target"
        else
            printf "  ${Y}○${N} %s — not set up\n" "$os"
        fi
    done
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    case "${1:-}" in
        nixos)        require_root; setup_nixos ;;
        kali)         require_root; setup_kali ;;
        debian)       require_root; setup_debian ;;
        --unmount|-u) require_root; shift; do_unmount "${1:-nixos}" ;;
        --status|-s)  do_status ;;
        --help|-h|"")
            sed -n '2,/^set -eu/p' "$0" | sed 's/^# \?//' | sed '$d'
            ;;
        *) error "Unknown: $1"; exit 1 ;;
    esac
}

main "$@"
