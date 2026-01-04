#!/bin/bash
# Build bootable USB from OCI container image
# Uses bootc-image-builder to create raw image, then writes to USB

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Config
OCI_TAR="src_oci/fedora-kinoite-41.tar"
USB="/dev/sda"
OUTPUT_DIR="dist_usb"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[!]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "Run as root"
[[ ! -f "$OCI_TAR" ]] && err "OCI image not found: $OCI_TAR"
[[ ! -b "$USB" ]] && err "USB not found: $USB"

# Check for podman
if ! command -v podman &>/dev/null; then
    err "podman not found. Install with: sudo apt install podman"
fi

echo "=========================================="
echo " Kinoite USB from OCI Image (Offline)"
echo "=========================================="
log "OCI: $OCI_TAR"
log "USB: $USB"
lsblk "$USB"
echo ""

# Auto-confirm with -y flag, otherwise prompt
if [[ "$1" == "-y" ]]; then
    log "Auto-confirmed"
else
    read -p "This will ERASE $USB. Type YES: " confirm
    [[ "$confirm" != "YES" ]] && err "Aborted"
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Image name for local storage
IMAGE_NAME="localhost/kinoite-usb:latest"

# Load OCI tar into root's podman storage (offline)
if ! podman image exists "$IMAGE_NAME" 2>/dev/null; then
    log "Loading OCI image into local storage..."
    podman load -i "$OCI_TAR"
    # Tag with consistent name
    LOADED_IMAGE=$(podman images --format "{{.Repository}}:{{.Tag}}" | grep -v "bootc-image-builder" | head -1)
    if [ -n "$LOADED_IMAGE" ] && [ "$LOADED_IMAGE" != "$IMAGE_NAME" ]; then
        podman tag "$LOADED_IMAGE" "$IMAGE_NAME" 2>/dev/null || true
    fi
else
    log "Image already loaded: $IMAGE_NAME"
fi

# Build raw disk image
log "Building raw image (this takes 10-15 minutes)..."
podman run \
    --rm \
    --privileged \
    --pull=never \
    --security-opt label=disable \
    -v "$(pwd)/$OUTPUT_DIR":/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    build \
    --type raw \
    --rootfs ext4 \
    --output /output \
    "$IMAGE_NAME"

# Find the built image
RAW_FILE=$(find "$OUTPUT_DIR" -name "*.raw" -type f | head -1)
[[ -z "$RAW_FILE" ]] && err "No raw image found in $OUTPUT_DIR"

log "Built image: $RAW_FILE"
log "Image size: $(du -h "$RAW_FILE" | cut -f1)"

# Wipe USB
log "Wiping USB..."
wipefs -af "$USB" 2>/dev/null || true
dd if=/dev/zero of="$USB" bs=1M count=100 status=none
sync

# Write raw image to USB
log "Writing image to USB (this takes 5-10 minutes)..."
dd if="$RAW_FILE" of="$USB" bs=4M status=progress conv=fsync
sync

# Expand root partition to fill USB
log "Expanding partition to fill USB..."
partprobe "$USB"
sleep 2

# Get the last partition number (usually root)
LAST_PART=$(lsblk -ln "$USB" | tail -1 | awk '{print $1}' | grep -oE '[0-9]+$')
if [ -n "$LAST_PART" ]; then
    parted -s "$USB" resizepart "$LAST_PART" 100% 2>/dev/null || warn "Could not auto-expand partition"
    partprobe "$USB"
    sleep 2
    e2fsck -f -y "${USB}${LAST_PART}" 2>/dev/null || true
    resize2fs "${USB}${LAST_PART}" 2>/dev/null || warn "Could not resize ext4"
fi
sync

echo ""
echo "=========================================="
echo -e "${GREEN} USB BUILD COMPLETE!${NC}"
echo "=========================================="
echo ""
echo "USB is now bootable with Kinoite"
echo "User: diego / Password: 1234567890"
echo ""
echo "To boot: plug USB into target machine and boot from USB"
echo ""
