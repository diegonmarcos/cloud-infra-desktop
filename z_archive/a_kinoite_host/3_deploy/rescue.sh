#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                         KINOITE RESCUE SCRIPT                             ║
# ║                                                                           ║
# ║   Fixes common boot issues on deployed Kinoite Surface systems            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Run this from a live USB or the build host when:
# - SELinux blocks boot ("Permission denied" spam, "Failed to allocate manager object")
# - Surface keyboard doesn't work at LUKS prompt
# - System freezes after LUKS unlock
#
# Usage:
#   sudo ./rescue.sh /dev/nvme0n1p2    # Specify LUKS partition
#   sudo ./rescue.sh                    # Auto-detect

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log() { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[x]${NC} %s\n" "$1"; exit 1; }

# Check root
[ "$(id -u)" -ne 0 ] && error "Run as root"

# Find LUKS partition
LUKS_PART="${1:-}"
if [ -z "$LUKS_PART" ]; then
    # Auto-detect
    LUKS_PART=$(lsblk -o NAME,FSTYPE -rn | grep crypto_LUKS | head -1 | awk '{print "/dev/"$1}')
    [ -z "$LUKS_PART" ] && error "No LUKS partition found. Specify manually: $0 /dev/nvme0n1p2"
fi

[ ! -b "$LUKS_PART" ] && error "Not a block device: $LUKS_PART"

log "LUKS partition: $LUKS_PART"

# ═══════════════════════════════════════════════════════════════════════════
# MOUNT SYSTEM
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
    log "Cleaning up mounts..."
    umount /mnt/rescue/boot/efi 2>/dev/null || true
    umount /mnt/rescue/etc 2>/dev/null || true
    umount /mnt/rescue/var 2>/dev/null || true
    umount /mnt/rescue/proc 2>/dev/null || true
    umount /mnt/rescue/sys 2>/dev/null || true
    umount /mnt/rescue/dev 2>/dev/null || true
    umount /mnt/rescue 2>/dev/null || true
    cryptsetup close cryptrescue 2>/dev/null || true
}
trap cleanup EXIT

log "Opening LUKS..."
if ! cryptsetup status cryptrescue >/dev/null 2>&1; then
    cryptsetup open "$LUKS_PART" cryptrescue
fi

log "Mounting @root..."
mkdir -p /mnt/rescue
mount -o subvol=@root /dev/mapper/cryptrescue /mnt/rescue

log "Mounting @etc-anon (for fixes)..."
mkdir -p /mnt/rescue/etc
mount -o subvol=@etc-anon /dev/mapper/cryptrescue /mnt/rescue/etc

log "Mounting @var-anon..."
mkdir -p /mnt/rescue/var
mount -o subvol=@var-anon /dev/mapper/cryptrescue /mnt/rescue/var

# Find and mount EFI
EFI_PART=$(lsblk -o NAME,PARTLABEL -rn | grep -i efi | head -1 | awk '{print "/dev/"$1}')
if [ -n "$EFI_PART" ] && [ -b "$EFI_PART" ]; then
    log "Mounting EFI: $EFI_PART"
    mkdir -p /mnt/rescue/boot/efi
    mount "$EFI_PART" /mnt/rescue/boot/efi
fi

# Bind mounts for chroot
mount --bind /dev /mnt/rescue/dev
mount --bind /proc /mnt/rescue/proc
mount --bind /sys /mnt/rescue/sys

# ═══════════════════════════════════════════════════════════════════════════
# FIX 1: SELINUX - SET TO PERMISSIVE
# ═══════════════════════════════════════════════════════════════════════════

log "Fixing SELinux..."
if [ -f /mnt/rescue/etc/selinux/config ]; then
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /mnt/rescue/etc/selinux/config
    log "  SELinux set to permissive in /etc/selinux/config"
else
    warn "  /etc/selinux/config not found"
fi

# ═══════════════════════════════════════════════════════════════════════════
# FIX 2: DRACUT CONFIG FOR SURFACE KEYBOARD + USB FALLBACK
# ═══════════════════════════════════════════════════════════════════════════

log "Creating dracut config for Surface keyboard..."
mkdir -p /mnt/rescue/etc/dracut.conf.d

LUKS_UUID=$(cryptsetup luksUUID "$LUKS_PART")

cat > /mnt/rescue/etc/dracut.conf.d/99-surface-keyboard.conf << 'DRACUTEOF'
# ═══════════════════════════════════════════════════════════════════════════
# SURFACE PRO 8 KEYBOARD + USB FALLBACK
# ═══════════════════════════════════════════════════════════════════════════
# Copied from working NixOS configuration (hardware-configuration.nix)
# These modules MUST load BEFORE the LUKS password prompt

# Surface Aggregator Module (SAM) - controls Type Cover
# CRITICAL: Load order matters! aggregator -> registry -> hub -> hid
force_drivers+=" surface_aggregator "
force_drivers+=" surface_aggregator_registry "
force_drivers+=" surface_aggregator_hub "

# Surface HID drivers for keyboard/touchpad over SAM
force_drivers+=" surface_hid "
force_drivers+=" surface_hid_core "

# Intel LPSS (Low Power Subsystem) - REQUIRED for SAM communication
force_drivers+=" intel_lpss "
force_drivers+=" intel_lpss_pci "

# Serial driver for SAM communication
force_drivers+=" 8250_dw "

# GPIO controller for Tiger Lake (Surface Pro 8 CPU)
force_drivers+=" pinctrl_tigerlake "

# HID for touch/multitouch input
force_drivers+=" hid_multitouch "
force_drivers+=" hid_generic "

# FALLBACK: Surface touchscreen modules (for on-screen keyboard)
force_drivers+=" i2c_hid "
force_drivers+=" i2c_hid_acpi "

# Intel touch controller
force_drivers+=" intel_ish_ipc "
force_drivers+=" intel_ishtp "
force_drivers+=" intel_ishtp_hid "

# ═══════════════════════════════════════════════════════════════════════════
# USB KEYBOARD FALLBACK - MUST WORK IMMEDIATELY
# ═══════════════════════════════════════════════════════════════════════════
# From NixOS: xhci_pci, thunderbolt, nvme, usb_storage, sd_mod
force_drivers+=" xhci_pci "
force_drivers+=" xhci_hcd "
force_drivers+=" thunderbolt "
force_drivers+=" usb_storage "
force_drivers+=" usbhid "
force_drivers+=" hid "

# Intel graphics for early display (Plymouth)
force_drivers+=" i915 "

# BTRFS support
force_drivers+=" btrfs "

# Include ALL modules, not just host-specific
hostonly="no"

# Add crypt module for LUKS
add_dracutmodules+=" crypt btrfs "
DRACUTEOF

log "  Created /etc/dracut.conf.d/99-surface-keyboard.conf"

# ═══════════════════════════════════════════════════════════════════════════
# FIX 3: USB KEYFILE FALLBACK (COPIED FROM NIXOS)
# ═══════════════════════════════════════════════════════════════════════════
# USB keyfile on Ventoy VTOYEFI partition (UUID: 223C-F3F8)
# Boot flow:
#   1. Wait up to 5 seconds for USB keyfile
#   2. If found, unlock automatically
#   3. If not found, prompt for password (fallback)

log "Creating USB keyfile hook for dracut..."
mkdir -p /mnt/rescue/usr/lib/dracut/modules.d/90usb-keyfile

cat > /mnt/rescue/usr/lib/dracut/modules.d/90usb-keyfile/module-setup.sh << 'HOOKEOF'
#!/bin/bash
check() { return 0; }
depends() { echo "crypt"; }
install() {
    inst_hook pre-mount 10 "$moddir/usb-keyfile.sh"
}
HOOKEOF
chmod +x /mnt/rescue/usr/lib/dracut/modules.d/90usb-keyfile/module-setup.sh

# USB keyfile script - matches NixOS preOpenCommands
cat > /mnt/rescue/usr/lib/dracut/modules.d/90usb-keyfile/usb-keyfile.sh << 'HOOKEOF'
#!/bin/bash
# USB Keyfile Fallback for LUKS
# Copied from NixOS hardware-configuration.nix preOpenCommands

USB_UUID="223C-F3F8"  # Ventoy VTOYEFI partition
KEYFILE_PATH="/.luks/surface.key"
MOUNT_POINT="/usb-key"

info "USB keyfile: Looking for USB device $USB_UUID..."

mkdir -p "$MOUNT_POINT"
attempts=0

while [ $attempts -lt 5 ]; do
    if [ -b "/dev/disk/by-uuid/$USB_UUID" ]; then
        info "USB keyfile: Found USB device, mounting..."
        if mount -t vfat -o ro "/dev/disk/by-uuid/$USB_UUID" "$MOUNT_POINT" 2>/dev/null; then
            if [ -f "${MOUNT_POINT}${KEYFILE_PATH}" ]; then
                info "USB keyfile: Found keyfile at ${KEYFILE_PATH}"
                # Copy keyfile to /run for cryptsetup to use
                cp "${MOUNT_POINT}${KEYFILE_PATH}" /run/luks-keyfile
                chmod 400 /run/luks-keyfile
                export LUKS_KEYFILE="/run/luks-keyfile"
            else
                warn "USB keyfile: Keyfile not found at ${KEYFILE_PATH}"
            fi
            umount "$MOUNT_POINT" 2>/dev/null || true
            break
        fi
    fi
    attempts=$((attempts + 1))
    info "USB keyfile: Waiting for USB... ($attempts/5)"
    sleep 1
done

if [ $attempts -eq 5 ]; then
    info "USB keyfile: USB not found, will prompt for password"
fi
HOOKEOF
chmod +x /mnt/rescue/usr/lib/dracut/modules.d/90usb-keyfile/usb-keyfile.sh

log "  Created USB keyfile dracut module"

# ═══════════════════════════════════════════════════════════════════════════
# FIX 4: KERNEL CMDLINE WITH SELINUX PERMISSIVE + USB KEYFILE
# ═══════════════════════════════════════════════════════════════════════════

log "Updating kernel cmdline..."
cat > /mnt/rescue/etc/dracut.conf.d/99-cmdline.conf << EOF
# Kernel command line for Surface dual-profile boot
# - enforcing=0: SELinux permissive (backup)
# - rd.luks.timeout=60: Give USB time to initialize
# - rd.luks.key: USB keyfile path (fallback to password if not found)
# - rd.driver.pre: Force early loading of keyboard modules
kernel_cmdline="rd.luks.uuid=$LUKS_UUID rd.luks.key=/run/luks-keyfile rd.luks.timeout=60 root=/dev/mapper/cryptouter rootflags=subvol=@root enforcing=0 rd.driver.pre=surface_aggregator,surface_hid,usbhid,xhci_pci quiet splash"

# Add USB keyfile module
add_dracutmodules+=" usb-keyfile "
EOF

log "  Created /etc/dracut.conf.d/99-cmdline.conf"

# ═══════════════════════════════════════════════════════════════════════════
# FIX 5: REBUILD INITRAMFS
# ═══════════════════════════════════════════════════════════════════════════

log "Rebuilding initramfs (this takes a few minutes)..."

# Find kernel version
KERNEL_VER=$(ls /mnt/rescue/usr/lib/modules/ | grep surface | head -1)
if [ -z "$KERNEL_VER" ]; then
    KERNEL_VER=$(ls /mnt/rescue/usr/lib/modules/ | head -1)
fi

if [ -z "$KERNEL_VER" ]; then
    error "No kernel found in /usr/lib/modules/"
fi

log "  Kernel version: $KERNEL_VER"

# Rebuild initramfs inside chroot
chroot /mnt/rescue /bin/bash -c "
    dracut --force --verbose /boot/initramfs-${KERNEL_VER}.img ${KERNEL_VER}
"

# Copy to EFI if needed
if [ -d /mnt/rescue/boot/efi/EFI ]; then
    log "  Copying kernel and initramfs to EFI..."
    cp /mnt/rescue/usr/lib/modules/${KERNEL_VER}/vmlinuz /mnt/rescue/boot/efi/vmlinuz 2>/dev/null || true
    cp /mnt/rescue/boot/initramfs-${KERNEL_VER}.img /mnt/rescue/boot/efi/initramfs.img 2>/dev/null || true
fi

# ═══════════════════════════════════════════════════════════════════════════
# FIX 6: UPDATE GRUB/REFIND WITH SELINUX=0 FALLBACK
# ═══════════════════════════════════════════════════════════════════════════

log "Updating bootloader config..."

# Check for rEFInd
if [ -f /mnt/rescue/boot/efi/EFI/refind/refind.conf ]; then
    log "  Found rEFInd, adding enforcing=0 to boot options..."
    sed -i 's/options "/options "enforcing=0 /' /mnt/rescue/boot/efi/EFI/refind/refind.conf 2>/dev/null || true
fi

# Check for GRUB
if [ -f /mnt/rescue/boot/efi/EFI/fedora/grub.cfg ]; then
    log "  Found GRUB config..."
    # Add enforcing=0 to default cmdline
    if [ -f /mnt/rescue/etc/default/grub ]; then
        if ! grep -q "enforcing=0" /mnt/rescue/etc/default/grub; then
            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="enforcing=0 /' /mnt/rescue/etc/default/grub
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

printf "\n"
printf "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}\n"
printf "${GREEN}║${NC}${BOLD}                    RESCUE COMPLETE                           ${GREEN}║${NC}\n"
printf "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
printf "\n"
log "Fixes applied:"
log "  1. SELinux set to permissive mode"
log "  2. Surface keyboard modules added to initramfs"
log "  3. USB keyboard fallback modules added"
log "  4. Initramfs rebuilt with new config"
log "  5. enforcing=0 added to kernel cmdline"
printf "\n"
log "Next steps:"
log "  1. Unmount and reboot into Surface"
log "  2. Type Cover keyboard should work at LUKS prompt"
log "  3. If not, USB keyboard will work as fallback"
log "  4. System should boot without SELinux errors"
printf "\n"
warn "If keyboard still doesn't work at LUKS:"
warn "  - Press any key on USB keyboard"
warn "  - Or add 'rd.break' to kernel cmdline for emergency shell"
printf "\n"
