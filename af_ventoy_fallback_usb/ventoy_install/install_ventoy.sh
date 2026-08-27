#!/bin/bash
# Ventoy Installation Script for Fallback USB
# This script downloads Ventoy and installs it to a USB drive
#
# Usage: sudo ./install_ventoy.sh /dev/sdX
#
# WARNING: This will ERASE the target drive!

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENTOY_VERSION="1.0.99"
VENTOY_URL="https://github.com/ventoy/Ventoy/releases/download/v${VENTOY_VERSION}/ventoy-${VENTOY_VERSION}-linux.tar.gz"
WORK_DIR="/tmp/ventoy_install"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_ok()   { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
log_info() { printf "${YELLOW}[INFO]${NC} %s\n" "$1"; }
log_head() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
log_err()  { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }

usage() {
    echo ""
    echo "Ventoy Installation Script"
    echo ""
    echo "Usage: sudo $0 /dev/sdX"
    echo ""
    echo "Options:"
    echo "  -u, --update    Update existing Ventoy installation"
    echo "  -h, --help      Show this help"
    echo ""
    echo "Examples:"
    echo "  sudo $0 /dev/sda         # Fresh install"
    echo "  sudo $0 -u /dev/sda      # Update existing"
    echo ""
    exit 0
}

# Parse arguments
UPDATE_MODE=false
TARGET_DEVICE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--update)
            UPDATE_MODE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        /dev/*)
            TARGET_DEVICE="$1"
            shift
            ;;
        *)
            log_err "Unknown option: $1"
            ;;
    esac
done

# Must be root
if [ "$(id -u)" != "0" ]; then
    log_err "This script must be run as root"
fi

# Check target device
if [ -z "$TARGET_DEVICE" ]; then
    echo ""
    echo "Available devices:"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "loop\|nvme"
    echo ""
    read -p "Enter target device (e.g., /dev/sda): " TARGET_DEVICE
fi

if [ ! -b "$TARGET_DEVICE" ]; then
    log_err "Device not found: $TARGET_DEVICE"
fi

# Confirm
log_head "Target Device Information"
lsblk "$TARGET_DEVICE" -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
echo ""

if [ "$UPDATE_MODE" = true ]; then
    read -p "Update Ventoy on $TARGET_DEVICE? (y/N): " CONFIRM
else
    echo -e "${RED}WARNING: All data on $TARGET_DEVICE will be ERASED!${NC}"
    read -p "Install Ventoy to $TARGET_DEVICE? (y/N): " CONFIRM
fi

if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    log_info "Aborted"
    exit 0
fi

# Download Ventoy
log_head "Downloading Ventoy ${VENTOY_VERSION}"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ ! -f "ventoy-${VENTOY_VERSION}-linux.tar.gz" ]; then
    wget -q --show-progress "$VENTOY_URL"
fi
log_ok "Downloaded Ventoy"

# Extract
tar xzf "ventoy-${VENTOY_VERSION}-linux.tar.gz"
cd "ventoy-${VENTOY_VERSION}"
log_ok "Extracted Ventoy"

# Unmount any partitions
log_info "Unmounting partitions..."
for part in ${TARGET_DEVICE}*; do
    umount "$part" 2>/dev/null || true
done

# Install Ventoy
log_head "Installing Ventoy"
if [ "$UPDATE_MODE" = true ]; then
    ./Ventoy2Disk.sh -u "$TARGET_DEVICE"
else
    ./Ventoy2Disk.sh -I "$TARGET_DEVICE"
fi
log_ok "Ventoy installed"

# Wait for partitions
sleep 2

# Mount Ventoy partition
log_head "Configuring Ventoy"
VENTOY_PART="${TARGET_DEVICE}1"
MOUNT_POINT="/mnt/ventoy_usb"

mkdir -p "$MOUNT_POINT"
mount "$VENTOY_PART" "$MOUNT_POINT"

# Copy ventoy config
log_info "Copying Ventoy configuration..."
mkdir -p "$MOUNT_POINT/ventoy"
cp -r "$SCRIPT_DIR/ventoy/"* "$MOUNT_POINT/ventoy/"
log_ok "Configuration copied"

# Create persistence directory
mkdir -p "$MOUNT_POINT/persistence"
log_ok "Persistence directory created"

# Unmount
umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

# Cleanup
log_head "Cleaning Up"
rm -rf "$WORK_DIR"
log_ok "Temporary files removed"

# Summary
log_head "Installation Complete"
echo ""
echo "Ventoy has been installed to $TARGET_DEVICE"
echo ""
echo "Next steps:"
echo "1. Build live ISOs:"
echo "   sudo ../debian-slim-surface_fallback_usb/build_live.sh"
echo "   sudo ../a_arch-surface_fallback_usb/build_live.sh"
echo "   sudo ../alpine_fallback_usb/build_live.sh"
echo ""
echo "2. Copy ISOs to Ventoy partition:"
echo "   mount ${TARGET_DEVICE}1 /mnt"
echo "   cp *.iso /mnt/"
echo "   umount /mnt"
echo ""
echo "3. Boot from USB and select your OS!"
echo ""
