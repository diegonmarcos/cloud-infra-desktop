#!/bin/sh
# rescue-chroot-nixos.sh — Set up chroot environment to build/repair NixOS from another Linux
# POSIX-compliant. Run as root or with sudo.
#
# Usage:
#   sudo ./rescue-chroot-nixos.sh [--mount-only|--shell|--build]
#
# Options:
#   --mount-only   Set up mounts and exit (for manual chroot)
#   --shell        Enter interactive shell in chroot (default)
#   --build        Build NixOS system and exit
#   --unmount      Clean up all mounts
#
# Requirements:
#   - NixOS btrfs pool mounted (LUKS unlocked)
#   - Run from any Linux with chroot support

set -eu

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION — Adjust these paths for your setup
# ═══════════════════════════════════════════════════════════════════════════════

# Where the LUKS pool is mounted (contains @nixos, @home-diego, etc.)
POOL_MOUNT="${POOL_MOUNT:-/run/media/diego/pool}"

# Chroot target directory
CHROOT_DIR="${CHROOT_DIR:-/tmp/nixos-chroot}"

# Btrfs subvolumes
NIX_SUBVOL="@nixos/nix"
HOME_SUBVOL="@home-diego"

# NixOS flake location (relative to home)
FLAKE_PATH="git/cloud-infra-desktop/aa_nixos-surface_host/src"

# ═══════════════════════════════════════════════════════════════════════════════
# AUTO-DETECT NIX STORE PATHS
# ═══════════════════════════════════════════════════════════════════════════════

detect_paths() {
    NIX_STORE="$POOL_MOUNT/$NIX_SUBVOL/store"

    if [ ! -d "$NIX_STORE" ]; then
        echo "ERROR: Nix store not found at $NIX_STORE" >&2
        echo "Is the LUKS pool unlocked and mounted at $POOL_MOUNT?" >&2
        exit 1
    fi

    # Find required packages in nix store
    NIX_BIN=$(find "$NIX_STORE" -maxdepth 1 -name "*-nix-2.*" -type d 2>/dev/null | head -1)
    BASH_PKG=$(find "$NIX_STORE" -maxdepth 1 -name "*-bash-5.*" -type d 2>/dev/null | head -1)
    COREUTILS=$(find "$NIX_STORE" -maxdepth 1 -name "*-coreutils-*" -type d 2>/dev/null | head -1)
    GIT_PKG=$(find "$NIX_STORE" -maxdepth 1 -name "*-git-minimal-*" -type d 2>/dev/null | head -1)
    GLIBC=$(find "$NIX_STORE" -maxdepth 1 -name "*-glibc-*" -type d 2>/dev/null | grep -v "dev$" | head -1)
    SSL_CERTS=$(find "$NIX_STORE" -maxdepth 1 -name "*-nss-cacert-*" -type d 2>/dev/null | head -1)

    # Validate all found
    for pkg in NIX_BIN BASH_PKG COREUTILS GIT_PKG GLIBC SSL_CERTS; do
        eval "val=\$$pkg"
        if [ -z "$val" ]; then
            echo "ERROR: Could not find $pkg in nix store" >&2
            exit 1
        fi
    done

    # Convert to chroot-relative paths (strip pool mount prefix)
    NIX_BIN_REL="${NIX_BIN#$POOL_MOUNT/$NIX_SUBVOL}/bin"
    BASH_REL="${BASH_PKG#$POOL_MOUNT/$NIX_SUBVOL}/bin/bash"
    COREUTILS_REL="${COREUTILS#$POOL_MOUNT/$NIX_SUBVOL}/bin"
    GIT_REL="${GIT_PKG#$POOL_MOUNT/$NIX_SUBVOL}/bin"
    SSL_CERTS_REL="${SSL_CERTS#$POOL_MOUNT/$NIX_SUBVOL}/etc/ssl/certs/ca-bundle.crt"

    echo "Detected nix store paths:"
    echo "  nix:       $NIX_BIN_REL"
    echo "  bash:      $BASH_REL"
    echo "  coreutils: $COREUTILS_REL"
    echo "  git:       $GIT_REL"
    echo "  ssl certs: $SSL_CERTS_REL"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MOUNT SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_mounts() {
    echo "Setting up chroot at $CHROOT_DIR..."

    # Create directory structure
    mkdir -p "$CHROOT_DIR"/{nix,proc,sys,dev,tmp,run,etc,bin,home/diego}
    mkdir -p "$CHROOT_DIR/dev/pts"
    mkdir -p "$CHROOT_DIR/dev/shm"

    # Bind mount nix store
    if ! mountpoint -q "$CHROOT_DIR/nix" 2>/dev/null; then
        mount --bind "$POOL_MOUNT/$NIX_SUBVOL" "$CHROOT_DIR/nix"
        echo "  Mounted: /nix"
    fi

    # Bind mount home
    if ! mountpoint -q "$CHROOT_DIR/home/diego" 2>/dev/null; then
        mount --bind "$POOL_MOUNT/$HOME_SUBVOL" "$CHROOT_DIR/home/diego"
        echo "  Mounted: /home/diego"
    fi

    # Mount kernel filesystems
    if ! mountpoint -q "$CHROOT_DIR/proc" 2>/dev/null; then
        mount -t proc proc "$CHROOT_DIR/proc"
        echo "  Mounted: /proc"
    fi

    if ! mountpoint -q "$CHROOT_DIR/sys" 2>/dev/null; then
        mount --rbind /sys "$CHROOT_DIR/sys"
        mount --make-rslave "$CHROOT_DIR/sys"
        echo "  Mounted: /sys"
    fi

    if ! mountpoint -q "$CHROOT_DIR/dev" 2>/dev/null; then
        mount --rbind /dev "$CHROOT_DIR/dev"
        mount --make-rslave "$CHROOT_DIR/dev"
        echo "  Mounted: /dev"
    fi

    # devpts for pseudo-terminals (needed for nix build)
    if ! mountpoint -q "$CHROOT_DIR/dev/pts" 2>/dev/null; then
        mount -t devpts devpts "$CHROOT_DIR/dev/pts" 2>/dev/null || true
        echo "  Mounted: /dev/pts"
    fi

    # tmpfs for /tmp
    if ! mountpoint -q "$CHROOT_DIR/tmp" 2>/dev/null; then
        mount -t tmpfs tmpfs "$CHROOT_DIR/tmp"
        echo "  Mounted: /tmp"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION FILES
# ═══════════════════════════════════════════════════════════════════════════════

setup_configs() {
    echo "Setting up configuration files..."

    # DNS resolution
    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"
    else
        echo "nameserver 8.8.8.8" > "$CHROOT_DIR/etc/resolv.conf"
        echo "nameserver 1.1.1.1" >> "$CHROOT_DIR/etc/resolv.conf"
    fi
    echo "  Created: /etc/resolv.conf"

    # passwd with root and nixbld users
    cat > "$CHROOT_DIR/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:Nobody:/var/empty:/bin/false
EOF
    # Add nixbld users (1-32)
    i=1
    while [ $i -le 32 ]; do
        echo "nixbld$i:x:$((30000 + i)):30000:Nix build user $i:/var/empty:/bin/false" >> "$CHROOT_DIR/etc/passwd"
        i=$((i + 1))
    done
    echo "  Created: /etc/passwd (with 32 nixbld users)"

    # group file
    cat > "$CHROOT_DIR/etc/group" << 'EOF'
root:x:0:
nogroup:x:65534:
EOF
    # nixbld group with all members
    printf "nixbld:x:30000:" >> "$CHROOT_DIR/etc/group"
    i=1
    while [ $i -le 32 ]; do
        [ $i -gt 1 ] && printf "," >> "$CHROOT_DIR/etc/group"
        printf "nixbld%d" "$i" >> "$CHROOT_DIR/etc/group"
        i=$((i + 1))
    done
    echo "" >> "$CHROOT_DIR/etc/group"
    echo "  Created: /etc/group"

    # Create /bin/sh and /bin/bash symlinks
    ln -sf "$BASH_REL" "$CHROOT_DIR/bin/sh"
    ln -sf "$BASH_REL" "$CHROOT_DIR/bin/bash"
    echo "  Created: /bin/sh, /bin/bash -> $BASH_REL"

    # Create /var/empty for nixbld users
    mkdir -p "$CHROOT_DIR/var/empty"
    chmod 555 "$CHROOT_DIR/var/empty"

    # Create nix profile script
    cat > "$CHROOT_DIR/etc/profile" << EOF
export PATH="$NIX_BIN_REL:$COREUTILS_REL:$GIT_REL:\$PATH"
export NIX_CONFIG="experimental-features = nix-command flakes"
export SSL_CERT_FILE="$SSL_CERTS_REL"
export NIX_SSL_CERT_FILE="\$SSL_CERT_FILE"
export HOME="/root"
export TERM="\${TERM:-xterm}"

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║              NIXOS RESCUE CHROOT ENVIRONMENT                      ║"
echo "╠═══════════════════════════════════════════════════════════════════╣"
echo "║  nix build .#nixosConfigurations.surface.config.system.build.toplevel"
echo "║  cd /home/diego/$FLAKE_PATH"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
EOF
    echo "  Created: /etc/profile"
}

# ═══════════════════════════════════════════════════════════════════════════════
# UNMOUNT
# ═══════════════════════════════════════════════════════════════════════════════

do_unmount() {
    echo "Unmounting chroot filesystems..."

    # Unmount in reverse order
    for mnt in "$CHROOT_DIR/dev/pts" "$CHROOT_DIR/dev/shm" "$CHROOT_DIR/dev" \
               "$CHROOT_DIR/sys" "$CHROOT_DIR/proc" "$CHROOT_DIR/tmp" \
               "$CHROOT_DIR/home/diego" "$CHROOT_DIR/nix"; do
        if mountpoint -q "$mnt" 2>/dev/null; then
            umount -R "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
            echo "  Unmounted: $mnt"
        fi
    done

    echo "Cleanup complete."
}

# ═══════════════════════════════════════════════════════════════════════════════
# ENTER CHROOT
# ═══════════════════════════════════════════════════════════════════════════════

enter_shell() {
    echo ""
    echo "Entering chroot shell..."
    echo "Type 'exit' to leave."
    echo ""

    chroot "$CHROOT_DIR" /bin/bash --login
}

do_build() {
    echo ""
    echo "Building NixOS system..."

    chroot "$CHROOT_DIR" /bin/bash -c "
        . /etc/profile
        cd /home/diego/$FLAKE_PATH
        nix build .#nixosConfigurations.surface.config.system.build.toplevel --no-link --print-out-paths
    "
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    # Check root
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: Must run as root (use sudo)" >&2
        exit 1
    fi

    # Parse arguments
    ACTION="${1:-shell}"

    case "$ACTION" in
        --unmount|-u)
            do_unmount
            exit 0
            ;;
        --mount-only|-m)
            detect_paths
            setup_mounts
            setup_configs
            echo ""
            echo "Chroot ready at $CHROOT_DIR"
            echo "Enter manually with: chroot $CHROOT_DIR /bin/bash --login"
            exit 0
            ;;
        --build|-b)
            detect_paths
            setup_mounts
            setup_configs
            do_build
            exit 0
            ;;
        --shell|-s|"")
            detect_paths
            setup_mounts
            setup_configs
            enter_shell
            exit 0
            ;;
        --help|-h)
            echo "Usage: $0 [--mount-only|--shell|--build|--unmount]"
            echo ""
            echo "Options:"
            echo "  --mount-only, -m   Set up mounts and exit"
            echo "  --shell, -s        Enter interactive shell (default)"
            echo "  --build, -b        Build NixOS system"
            echo "  --unmount, -u      Clean up all mounts"
            echo "  --help, -h         Show this help"
            echo ""
            echo "Environment variables:"
            echo "  POOL_MOUNT   Where LUKS pool is mounted (default: /run/media/diego/pool)"
            echo "  CHROOT_DIR   Chroot directory (default: /tmp/nixos-chroot)"
            exit 0
            ;;
        *)
            echo "Unknown option: $ACTION" >&2
            echo "Use --help for usage" >&2
            exit 1
            ;;
    esac
}

main "$@"
