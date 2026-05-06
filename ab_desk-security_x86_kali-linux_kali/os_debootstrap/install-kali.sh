#!/bin/bash
# Kali Linux Debootstrap Installation Script
# Target: /dev/nvme0n1p7 (25GB)
# Includes: linux-surface kernel for Surface Pro keyboard support

set -e

# Configuration
DEVICE="/dev/nvme0n1p7"
MOUNT="/mnt/kali"
HOSTNAME="kali-surface"
USERNAME="diego"
PASSWORD="1234567890"
KALI_MIRROR="http://http.kali.org/kali"
KALI_RELEASE="kali-rolling"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[!]${NC} $1"; exit 1; }

# Check root
[[ $EUID -ne 0 ]] && error "Run as root: sudo $0"

# Check debootstrap
if ! command -v debootstrap &>/dev/null; then
    log "Installing debootstrap..."
    apt-get update && apt-get install -y debootstrap
fi

# Step 1: Format partition
log "Formatting $DEVICE as ext4..."
mkfs.ext4 -F -L "kali-root" "$DEVICE"

# Step 2: Mount
log "Mounting $DEVICE to $MOUNT..."
mkdir -p "$MOUNT"
mount "$DEVICE" "$MOUNT"

# Step 3: Debootstrap
log "Running debootstrap (this takes 5-10 minutes)..."
debootstrap --arch=amd64 "$KALI_RELEASE" "$MOUNT" "$KALI_MIRROR"

# Step 4: Mount virtual filesystems
log "Mounting proc/sys/dev..."
mount -t proc none "$MOUNT/proc"
mount -t sysfs none "$MOUNT/sys"
mount --bind /dev "$MOUNT/dev"
mount --bind /dev/pts "$MOUNT/dev/pts"

# Step 5: Copy resolv.conf for network
cp /etc/resolv.conf "$MOUNT/etc/resolv.conf"

# Step 6: Generate fstab
UUID=$(blkid -s UUID -o value "$DEVICE")
echo "UUID=$UUID / ext4 defaults 0 1" > "$MOUNT/etc/fstab"
log "Generated fstab with UUID=$UUID"

# Step 7: Set hostname
echo "$HOSTNAME" > "$MOUNT/etc/hostname"
cat > "$MOUNT/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# Step 8: Configure apt sources
cat > "$MOUNT/etc/apt/sources.list" << EOF
deb $KALI_MIRROR $KALI_RELEASE main contrib non-free non-free-firmware
deb-src $KALI_MIRROR $KALI_RELEASE main contrib non-free non-free-firmware
EOF

# Step 9: Copy chroot setup script
cp "$(dirname "$0")/chroot-setup.sh" "$MOUNT/tmp/"
chmod +x "$MOUNT/tmp/chroot-setup.sh"

# Step 10: Run chroot setup
log "Running chroot configuration..."
chroot "$MOUNT" /bin/bash /tmp/chroot-setup.sh "$USERNAME" "$PASSWORD"

# Step 11: Cleanup
log "Cleaning up..."
rm -f "$MOUNT/tmp/chroot-setup.sh"
umount "$MOUNT/dev/pts" 2>/dev/null || true
umount "$MOUNT/dev" 2>/dev/null || true
umount "$MOUNT/proc" 2>/dev/null || true
umount "$MOUNT/sys" 2>/dev/null || true
umount "$MOUNT" 2>/dev/null || true

log "Kali installation complete!"
log "Update GRUB with: sudo update-grub"
log "Then reboot and select 'Kali Linux' from GRUB menu"
log "Login: $USERNAME / $PASSWORD"
