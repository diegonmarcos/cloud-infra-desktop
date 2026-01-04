#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# Kinoite KDE Auth - Build Raw Disk Image from OCI Container
# ═══════════════════════════════════════════════════════════════════════════════
#
# Builds a bootable raw disk image from the Fedora Kinoite OCI image.
# Profile: KDE Auth (diego with NOPASSWD sudo, auto-login)
#
# Source: src_oci/fedora-kinoite-41.tar (OCI image)
# Output: dist_raw/kinoite-kde-auth.raw
#
# Requirements:
#   - podman, qemu-img, libguestfs-tools (guestfish, virt-customize)
#   - Sudo access for disk operations
#
# Usage:
#   ./build.sh build    # Build the raw image
#   ./build.sh clean    # Remove build artifacts
#   ./build.sh info     # Show image info
#   ./build.sh test     # Launch VM with QEMU for testing
#
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
OCI_TAR="$BASE_DIR/src_oci/fedora-kinoite-41.tar"
OCI_IMAGE="fedora-kinoite:41-local"
OUTPUT_DIR="$BASE_DIR/dist_raw"
OUTPUT_RAW="$OUTPUT_DIR/kinoite-kde-auth.raw"
DISK_SIZE="40G"

# Profile: KDE Auth (from ARCHITECTURE.md)
USER_NAME="diego"
USER_PASS="1234567890"
USER_UID="1000"
HOSTNAME="kinoite-kde"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
step()  { echo -e "\n${CYAN}═══════════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}[STEP]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# Preflight Checks
# ─────────────────────────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in podman qemu-img guestfish virt-customize; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing: ${missing[*]}\nInstall: sudo dnf install podman qemu-img libguestfs-tools"
    fi

    [ -f "$OCI_TAR" ] || error "OCI tar not found: $OCI_TAR"
}

# ─────────────────────────────────────────────────────────────────────────────
# Load OCI Image into Podman
# ─────────────────────────────────────────────────────────────────────────────
load_oci_image() {
    step "Loading OCI image into podman"

    if podman image exists "$OCI_IMAGE" 2>/dev/null; then
        log "Image already loaded: $OCI_IMAGE"
        return 0
    fi

    log "Loading: $OCI_TAR"
    podman load -i "$OCI_TAR"

    # Tag with local name
    local src
    src=$(podman images --format "{{.Repository}}:{{.Tag}}" | grep -E "fedora.*kinoite.*41" | head -1 || true)
    if [ -n "$src" ]; then
        podman tag "$src" "$OCI_IMAGE"
        log "Tagged: $OCI_IMAGE"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Create Raw Disk Image
# ─────────────────────────────────────────────────────────────────────────────
create_raw() {
    step "Creating raw disk image ($DISK_SIZE)"

    mkdir -p "$OUTPUT_DIR"

    [ -f "$OUTPUT_RAW" ] && { warn "Removing existing: $OUTPUT_RAW"; rm -f "$OUTPUT_RAW"; }

    # Create sparse raw file
    truncate -s "$DISK_SIZE" "$OUTPUT_RAW"
    log "Created: $OUTPUT_RAW"
}

# ─────────────────────────────────────────────────────────────────────────────
# Export Container Rootfs
# ─────────────────────────────────────────────────────────────────────────────
export_rootfs() {
    step "Exporting container filesystem"

    local rootfs="$OUTPUT_DIR/rootfs.tar"
    local cid

    cid=$(podman create "$OCI_IMAGE" /bin/true)
    log "Container: $cid"

    podman export "$cid" -o "$rootfs"
    podman rm "$cid" >/dev/null

    log "Exported: $(du -h "$rootfs" | cut -f1)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Partition and Populate Disk
# ─────────────────────────────────────────────────────────────────────────────
build_disk() {
    step "Partitioning and populating raw disk"

    local rootfs="$OUTPUT_DIR/rootfs.tar"

    # Create fstab content file
    local fstab_file="$OUTPUT_DIR/fstab.tmp"
    cat > "$fstab_file" << 'FSTABEOF'
# /etc/fstab
LABEL=fedora    /           ext4    defaults        1 1
LABEL=EFI       /boot/efi   vfat    umask=0077      0 1
FSTABEOF

    # Use guestfish to create partitions and extract rootfs
    guestfish --rw -a "$OUTPUT_RAW" <<GFEOF
run

# GPT partition table
part-init /dev/sda gpt

# EFI System Partition (512 MB)
part-add /dev/sda p 2048 1050623
part-set-gpt-type /dev/sda 1 C12A7328-F81F-11D2-BA4B-00A0C93EC93B

# Root partition (rest of disk)
part-add /dev/sda p 1050624 -2048

# Format
mkfs vfat /dev/sda1 label:EFI
mkfs ext4 /dev/sda2 label:fedora

# Mount and extract
mount /dev/sda2 /
mkdir-p /boot/efi
mount /dev/sda1 /boot/efi

tar-in $rootfs / xattrs:true selinux:true

# Copy fstab
copy-in $fstab_file /etc
mv /etc/fstab.tmp /etc/fstab

umount-all
GFEOF

    rm -f "$fstab_file"
    log "Disk populated"
}

# ─────────────────────────────────────────────────────────────────────────────
# Apply KDE Auth Configuration
# ─────────────────────────────────────────────────────────────────────────────
apply_config() {
    step "Applying KDE Auth profile (diego, NOPASSWD sudo, auto-login)"

    # Disable network to avoid passt issues
    export LIBGUESTFS_BACKEND=direct

    sudo -E virt-customize --no-network -a "$OUTPUT_RAW" \
        --hostname "$HOSTNAME" \
        --timezone "UTC" \
        \
        --run-command "id $USER_NAME &>/dev/null || useradd -m -u $USER_UID -G wheel -s /bin/bash $USER_NAME" \
        --password "$USER_NAME:password:$USER_PASS" \
        --run-command "echo 'root:$USER_PASS' | chpasswd" \
        \
        --write "/etc/sudoers.d/$USER_NAME:$USER_NAME ALL=(ALL) NOPASSWD: ALL" \
        --chmod "0440:/etc/sudoers.d/$USER_NAME" \
        \
        --run-command "systemctl enable sshd" \
        --write "/etc/ssh/sshd_config.d/99-local.conf:PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes" \
        --run-command "firewall-offline-cmd --add-service=ssh 2>/dev/null || true" \
        \
        --mkdir "/var/home/$USER_NAME/.ssh" \
        --chmod "0700:/var/home/$USER_NAME/.ssh" \
        --run-command "chown -R $USER_UID:$USER_UID /var/home/$USER_NAME" \
        \
        --write "/etc/sddm.conf.d/autologin.conf:[Autologin]
User=$USER_NAME
Session=plasma.desktop" \
        \
        --selinux-relabel

    log "Configuration applied"
}

# ─────────────────────────────────────────────────────────────────────────────
# Install Bootloader (GRUB2 EFI)
# ─────────────────────────────────────────────────────────────────────────────
install_bootloader() {
    step "Installing GRUB2 EFI bootloader"

    # Create a script to properly setup bootloader
    local boot_script="$OUTPUT_DIR/setup-boot.sh"
    cat > "$boot_script" << 'BOOTEOF'
#!/bin/bash
set -x

# Fedora Kinoite uses ostree, need to find the kernel
KERNEL=$(ls /usr/lib/modules/ | sort -V | tail -1)
echo "Kernel version: $KERNEL"

# Create EFI directories
mkdir -p /boot/efi/EFI/BOOT
mkdir -p /boot/efi/EFI/fedora

# Find kernel and initramfs
if [ -f "/usr/lib/modules/$KERNEL/vmlinuz" ]; then
    cp "/usr/lib/modules/$KERNEL/vmlinuz" /boot/efi/EFI/fedora/vmlinuz
fi

# Generate initramfs
if command -v dracut &>/dev/null; then
    dracut --force /boot/efi/EFI/fedora/initramfs.img "$KERNEL" 2>/dev/null || true
fi

# Get root UUID
ROOT_UUID=$(blkid -s UUID -o value /dev/sda2 2>/dev/null || echo "LABEL=fedora")

# Install GRUB if available
if command -v grub2-install &>/dev/null; then
    grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=fedora --removable 2>/dev/null || true
fi

# Create minimal grub.cfg
cat > /boot/efi/EFI/fedora/grub.cfg << GRUBEOF
set timeout=5
set default=0

menuentry 'Fedora Kinoite' {
    linux /EFI/fedora/vmlinuz root=UUID=$ROOT_UUID ro quiet
    initrd /EFI/fedora/initramfs.img
}
GRUBEOF

# Copy to BOOT directory for removable media boot
cp /boot/efi/EFI/fedora/grub.cfg /boot/efi/EFI/BOOT/ 2>/dev/null || true

# Install shimx64.efi and grubx64.efi if available
for src in /usr/share/grub/x86_64-efi /boot/efi/EFI/fedora; do
    if [ -f "$src/shimx64.efi" ]; then
        cp "$src/shimx64.efi" /boot/efi/EFI/BOOT/BOOTX64.EFI
        break
    fi
done

if [ -f /usr/share/grub/x86_64-efi/grubx64.efi ]; then
    cp /usr/share/grub/x86_64-efi/grubx64.efi /boot/efi/EFI/BOOT/
fi

# If no GRUB, create a minimal UEFI stub (systemd-boot style)
if [ ! -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]; then
    # Try to use the kernel as EFI stub if it supports it
    if [ -f /boot/efi/EFI/fedora/vmlinuz ]; then
        cp /boot/efi/EFI/fedora/vmlinuz /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true
    fi
fi

echo "Boot setup complete"
ls -la /boot/efi/EFI/BOOT/
ls -la /boot/efi/EFI/fedora/
BOOTEOF
    chmod +x "$boot_script"

    sudo -E virt-customize --no-network -a "$OUTPUT_RAW" \
        --copy-in "$boot_script:/tmp" \
        --run "/tmp/setup-boot.sh"

    rm -f "$boot_script"
    log "Bootloader installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# Finalize
# ─────────────────────────────────────────────────────────────────────────────
finalize() {
    step "Finalizing raw image"

    rm -f "$OUTPUT_DIR/rootfs.tar"
    log "Cleaned temporary files"

    echo ""
    ls -lh "$OUTPUT_RAW"
    file "$OUTPUT_RAW"
}

# ─────────────────────────────────────────────────────────────────────────────
# Clean
# ─────────────────────────────────────────────────────────────────────────────
clean() {
    step "Cleaning build artifacts"

    rm -f "$OUTPUT_DIR/rootfs.tar" "$OUTPUT_RAW"

    if podman image exists "$OCI_IMAGE" 2>/dev/null; then
        read -p "Remove podman image $OCI_IMAGE? [y/N] " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] && podman rmi "$OCI_IMAGE"
    fi

    log "Cleaned"
}

# ─────────────────────────────────────────────────────────────────────────────
# Info
# ─────────────────────────────────────────────────────────────────────────────
info() {
    step "Image Information"

    if [ -f "$OUTPUT_RAW" ]; then
        ls -lh "$OUTPUT_RAW"
        file "$OUTPUT_RAW"
        echo ""
        log "Test with: $0 test"
    else
        warn "Image not found: $OUTPUT_RAW"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Test VM
# ─────────────────────────────────────────────────────────────────────────────
test_vm() {
    step "Launching test VM"

    [ -f "$OUTPUT_RAW" ] || error "Image not found: $OUTPUT_RAW"

    local ovmf="/usr/share/OVMF/OVMF_CODE_4M.fd"
    [ -f "$ovmf" ] || ovmf="/usr/share/edk2/ovmf/OVMF_CODE.fd"
    [ -f "$ovmf" ] || ovmf="/usr/share/OVMF/OVMF_CODE.fd"
    [ -f "$ovmf" ] || ovmf="/usr/share/edk2-ovmf/x64/OVMF_CODE.fd"
    [ -f "$ovmf" ] || error "OVMF not found. Install ovmf or edk2-ovmf"

    log "Starting QEMU (Ctrl+C to stop)..."
    qemu-system-x86_64 \
        -enable-kvm \
        -m 4G \
        -cpu host \
        -smp 2 \
        -drive file="$OUTPUT_RAW",format=raw,if=virtio \
        -bios "$ovmf" \
        -nic user,hostfwd=tcp::2222-:22
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Build
# ─────────────────────────────────────────────────────────────────────────────
build() {
    cat <<'BANNER'

╔═══════════════════════════════════════════════════════════════════════════════╗
║                   Kinoite KDE Auth - Raw Disk Build                           ║
║                   Profile: diego (NOPASSWD sudo, auto-login)                  ║
╚═══════════════════════════════════════════════════════════════════════════════╝

BANNER

    check_deps
    load_oci_image
    create_raw
    export_rootfs
    build_disk
    apply_config
    install_bootloader
    finalize

    cat <<EOF

╔═══════════════════════════════════════════════════════════════════════════════╗
║                              BUILD COMPLETE                                    ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║  Output: $OUTPUT_RAW
║  Format: raw (dd-able to USB/disk, or use with QEMU)
║  Size:   $DISK_SIZE
║  User:   $USER_NAME | Password: $USER_PASS
║  SSH:    Enabled (port 22)
║  Login:  Auto-login to KDE Plasma
╠═══════════════════════════════════════════════════════════════════════════════╣
║  Test:   ./build.sh test                                                      ║
║          ssh -p 2222 $USER_NAME@localhost                                     ║
╚═══════════════════════════════════════════════════════════════════════════════╝
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry Point
# ─────────────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 {build|clean|info|test}

Commands:
  build   Build raw disk image from OCI container
  clean   Remove build artifacts
  info    Show image information
  test    Launch VM with QEMU for testing

Source: $OCI_TAR
Output: $OUTPUT_RAW
EOF
}

case "${1:-}" in
    build) build ;;
    clean) clean ;;
    info)  info ;;
    test)  test_vm ;;
    *)     usage; exit 1 ;;
esac
