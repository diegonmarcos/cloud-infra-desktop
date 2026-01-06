#!/bin/bash
# Arch Linux Bootstrap Install Script
# Run from Kubuntu to install Arch to nvme0n1p6
# Surface keyboard will work on FIRST BOOT!

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="/dev/nvme0n1p6"
MOUNT="/mnt/arch"
BOOTSTRAP="/home/diego/archlinux-bootstrap.tar.zst"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# Check root
[ "$(id -u)" != "0" ] && error "Run as root: sudo $0"

# Check bootstrap exists
[ ! -f "$BOOTSTRAP" ] && error "Bootstrap not found: $BOOTSTRAP"

# Confirm
echo ""
echo "========================================"
echo "  Arch Linux Bootstrap Install"
echo "========================================"
echo ""
echo "  Target: $TARGET (nvme0n1p6)"
echo "  Mount:  $MOUNT"
echo "  Source: $BOOTSTRAP"
echo ""
echo "  This will ERASE nvme0n1p6!"
echo ""
read -p "Continue? [y/N] " confirm
[ "$confirm" != "y" ] && exit 0

# Step 1: Format partition
log "Formatting $TARGET as ext4..."
mkfs.ext4 -F -L "arch" "$TARGET"

# Step 2: Mount
log "Mounting $TARGET to $MOUNT..."
mkdir -p "$MOUNT"
mount "$TARGET" "$MOUNT"

# Step 3: Extract bootstrap
log "Extracting bootstrap (this takes a minute)..."
tar -xf "$BOOTSTRAP" -C "$MOUNT" --strip-components=1

# Step 4: Setup resolv.conf
log "Setting up DNS..."
cp /etc/resolv.conf "$MOUNT/etc/resolv.conf"

# Step 5: Mount necessary filesystems
log "Mounting proc/sys/dev..."
mount -t proc /proc "$MOUNT/proc"
mount -t sysfs /sys "$MOUNT/sys"
mount --rbind /dev "$MOUNT/dev"
mount --make-rslave "$MOUNT/dev"

# Step 6: Copy config files
log "Copying config files..."
cp "$SCRIPT_DIR/pacman.conf" "$MOUNT/etc/pacman.conf"
cp "$SCRIPT_DIR/chroot-setup.sh" "$MOUNT/root/chroot-setup.sh"
chmod +x "$MOUNT/root/chroot-setup.sh"

# Step 7: Initialize pacman
log "Initializing pacman keyring..."
chroot "$MOUNT" /bin/bash -c "pacman-key --init"
chroot "$MOUNT" /bin/bash -c "pacman-key --populate archlinux"

# Step 8: Add linux-surface repo key (download directly - keyservers unreliable)
log "Adding linux-surface GPG key..."
curl -s "https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc" | chroot "$MOUNT" /bin/bash -c "pacman-key --add -"
chroot "$MOUNT" /bin/bash -c "pacman-key --lsign-key 56C464BAAC421453"

# Step 9: Update and install base
log "Installing base system + linux-surface (this takes several minutes)..."
chroot "$MOUNT" /bin/bash -c "pacman -Sy --noconfirm base linux-surface linux-surface-headers linux-firmware iptsd"

# Step 10: Run chroot setup
log "Running chroot setup..."
chroot "$MOUNT" /bin/bash /root/chroot-setup.sh

# Step 11: Generate fstab
log "Generating fstab..."
UUID=$(blkid -s UUID -o value "$TARGET")
cat > "$MOUNT/etc/fstab" << EOF
# /etc/fstab - Arch Linux Surface
UUID=$UUID  /  ext4  defaults  0  1
EOF

# Step 12: Install bootloader
log "Installing systemd-boot..."
chroot "$MOUNT" /bin/bash -c "bootctl install --path=/boot" || warn "bootctl failed - may need manual setup"

# Create boot entry
mkdir -p "$MOUNT/boot/loader/entries"
PARTUUID=$(blkid -s PARTUUID -o value "$TARGET")

cat > "$MOUNT/boot/loader/loader.conf" << EOF
default arch-surface.conf
timeout 3
console-mode max
editor no
EOF

cat > "$MOUNT/boot/loader/entries/arch-surface.conf" << EOF
title   Arch Linux Surface
linux   /vmlinuz-linux-surface
initrd  /initramfs-linux-surface.img
options root=PARTUUID=$PARTUUID rw
EOF

log "Creating fallback entry..."
cat > "$MOUNT/boot/loader/entries/arch-surface-fallback.conf" << EOF
title   Arch Linux Surface (fallback)
linux   /vmlinuz-linux-surface
initrd  /initramfs-linux-surface-fallback.img
options root=PARTUUID=$PARTUUID rw
EOF

# Cleanup
log "Cleaning up..."
umount -R "$MOUNT/dev" 2>/dev/null || true
umount "$MOUNT/proc" 2>/dev/null || true
umount "$MOUNT/sys" 2>/dev/null || true
umount "$MOUNT" 2>/dev/null || true

echo ""
echo "========================================"
echo "  Arch Linux installed successfully!"
echo "========================================"
echo ""
echo "  Surface keyboard will work on first boot!"
echo ""
echo "  To boot into Arch:"
echo "  1. Reboot"
echo "  2. Select 'Arch Linux Surface' from boot menu"
echo ""
echo "  After first boot, run:"
echo "    ./install.sh install   # Install all tools"
echo ""
