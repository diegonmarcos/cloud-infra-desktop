#!/bin/bash
# Build Debian Surface Live ISO
# Creates a minimal Debian live image with Surface drivers, boots to RAM
#
# Usage: sudo ./build_live.sh
#
# Output: debian-surface-live.iso (~800MB)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/var/tmp/debian-surface-live"  # Use /var/tmp for more space (tmpfs /tmp is too small)
OUTPUT_DIR="$SCRIPT_DIR"
ISO_NAME="debian-surface-live.iso"

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

# Must be root
if [ "$(id -u)" != "0" ]; then
    log_err "This script must be run as root"
fi

# Check dependencies
log_head "Checking Dependencies"
for cmd in debootstrap mksquashfs xorriso; do
    if ! command -v $cmd >/dev/null 2>&1; then
        log_info "Installing $cmd..."
        apt-get update && apt-get install -y $cmd live-build squashfs-tools xorriso
    fi
done
log_ok "All dependencies installed"

# Clean previous build
log_head "Preparing Build Environment"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"/{chroot,image/{live,isolinux,boot/grub}}
cd "$BUILD_DIR"
log_ok "Build directory ready: $BUILD_DIR"

# Debootstrap minimal Debian
log_head "Installing Base System (debootstrap)"
debootstrap --arch=amd64 --variant=minbase bookworm chroot http://deb.debian.org/debian
log_ok "Base system installed"

# Configure chroot
log_head "Configuring Chroot Environment"

# Set hostname
echo "debian-surface" > chroot/etc/hostname

# Configure apt sources
cat > chroot/etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

# Mount necessary filesystems
mount --bind /dev chroot/dev
mount --bind /dev/pts chroot/dev/pts
mount -t proc proc chroot/proc
mount -t sysfs sysfs chroot/sys

# Install packages in chroot
log_head "Installing Packages in Chroot"
cat > chroot/tmp/install.sh << 'CHROOT_SCRIPT'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# Update
apt-get update

# Add linux-surface repo
apt-get install -y curl gnupg
curl -fsSL https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc | \
    gpg --dearmor -o /etc/apt/trusted.gpg.d/linux-surface.gpg
echo "deb [arch=amd64] https://pkg.surfacelinux.com/debian release main" > /etc/apt/sources.list.d/linux-surface.list
apt-get update

# Install Surface kernel (critical for keyboard/wifi)
apt-get install -y linux-image-surface linux-headers-surface iptsd libwacom-surface firmware-misc-nonfree

# Base system
apt-get install -y \
    systemd-sysv dbus locales console-setup \
    sudo bash zsh fish \
    network-manager wpasupplicant iwd \
    openssh-client curl wget git \
    live-boot live-boot-initramfs-tools

# Lightweight GUI (ultra-minimal)
apt-get install -y \
    xorg openbox \
    sakura \
    pcmanfm \
    mesa-utils fonts-dejavu

# CLI tools
apt-get install -y \
    vim nano \
    htop btop \
    ripgrep jq fzf tmux neofetch

# Development (for Claude Code)
apt-get install -y nodejs npm

# Browser
apt-get install -y lynx

# Clean cache
apt-get clean
rm -rf /var/lib/apt/lists/*

# Configure locales
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen

# Create user
useradd -m -G sudo,video,input,audio -s /usr/bin/fish diego
echo "diego:1234567890" | chpasswd
echo "root:1234567890" | chpasswd

# Passwordless sudo
echo "%sudo ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

# Enable services
systemctl enable NetworkManager || true
systemctl enable iptsd || true

# Create xinitrc
echo "exec openbox-session" > /home/diego/.xinitrc
chown diego:diego /home/diego/.xinitrc

# Create openbox config directory
mkdir -p /home/diego/.config/openbox

# Openbox menu (right-click)
cat > /home/diego/.config/openbox/menu.xml << 'MENU'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
<menu id="root-menu" label="Menu">
  <item label="Terminal"><action name="Execute"><command>sakura</command></action></item>
  <item label="Files"><action name="Execute"><command>pcmanfm</command></action></item>
  <separator />
  <item label="WiFi (nmtui)"><action name="Execute"><command>sakura -e nmtui</command></action></item>
  <item label="Claude Code"><action name="Execute"><command>sakura -e claude</command></action></item>
  <item label="System Monitor"><action name="Execute"><command>sakura -e btop</command></action></item>
  <separator />
  <item label="Reboot"><action name="Execute"><command>systemctl reboot</command></action></item>
  <item label="Shutdown"><action name="Execute"><command>systemctl poweroff</command></action></item>
</menu>
</openbox_menu>
MENU

# Openbox autostart
cat > /home/diego/.config/openbox/autostart << 'AUTOSTART'
# Set background color
xsetroot -solid "#2e3440" &
AUTOSTART

# Openbox rc.xml (keyboard shortcuts)
cat > /home/diego/.config/openbox/rc.xml << 'RCXML'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
<keyboard>
  <keybind key="W-Return"><action name="Execute"><command>sakura</command></action></keybind>
  <keybind key="W-e"><action name="Execute"><command>pcmanfm</command></action></keybind>
  <keybind key="W-q"><action name="Close"/></keybind>
  <keybind key="A-F4"><action name="Close"/></keybind>
  <keybind key="A-Tab"><action name="NextWindow"/></keybind>
</keyboard>
<mouse><context name="Root"><mousebind button="Right" action="Press"><action name="ShowMenu"><menu>root-menu</menu></action></mousebind></context></mouse>
</openbox_config>
RCXML

chown -R diego:diego /home/diego/.config

# Install Claude Code (do this last, takes time)
npm install -g @anthropic-ai/claude-code || true

# Create autologin
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF2'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin diego --noclear %I $TERM
EOF2

# Create welcome message
cat > /home/diego/.bash_profile << 'EOF2'
echo ""
echo "=================================="
echo "  Debian Surface Recovery"
echo "=================================="
echo ""
echo "Commands:"
echo "  startx     - Start Openbox GUI"
echo "  nmtui      - WiFi configuration"
echo "  claude     - Claude Code CLI"
echo "  btop       - System monitor"
echo ""
neofetch --off
EOF2
chown diego:diego /home/diego/.bash_profile

# critical: update initramfs to ensure live-boot hooks are present
update-initramfs -u -k all

echo "Chroot installation complete!"
CHROOT_SCRIPT

chmod +x chroot/tmp/install.sh
chroot chroot /tmp/install.sh
log_ok "Packages installed in chroot"

# Unmount chroot filesystems
umount chroot/sys chroot/proc chroot/dev/pts chroot/dev

# Create squashfs
log_head "Creating SquashFS Image"
mksquashfs chroot image/live/filesystem.squashfs -comp xz -Xbcj x86 -b 1M -Xdict-size 1M
log_ok "SquashFS created"

# Copy kernel and initrd
log_head "Copying Kernel and Initrd"
cp chroot/boot/vmlinuz-*-surface image/live/vmlinuz
cp chroot/boot/initrd.img-*-surface image/live/initrd.img
log_ok "Kernel files copied"

# Create GRUB config
log_head "Creating GRUB Configuration"
cat > image/boot/grub/grub.cfg << 'EOF'
set timeout=5
set default=0

menuentry "Debian Surface Recovery (Load to RAM)" {
    linux /live/vmlinuz boot=live toram quiet splash
    initrd /live/initrd.img
}

menuentry "Debian Surface Recovery (Normal)" {
    linux /live/vmlinuz boot=live quiet splash
    initrd /live/initrd.img
}

menuentry "Debian Surface Recovery (Debug)" {
    linux /live/vmlinuz boot=live debug
    initrd /live/initrd.img
}
EOF
log_ok "GRUB config created"

# Setup BIOS boot (isolinux)
log_head "Setting up BIOS Boot (isolinux)"
apt-get install -y isolinux syslinux-common
cp /usr/lib/ISOLINUX/isolinux.bin image/isolinux/
cp /usr/lib/syslinux/modules/bios/{ldlinux.c32,libcom32.c32,libutil.c32,vesamenu.c32} image/isolinux/

cat > image/isolinux/isolinux.cfg << 'EOF'
DEFAULT vesamenu.c32
TIMEOUT 50
PROMPT 0
MENU TITLE Debian Surface Recovery

LABEL toram
    MENU LABEL Debian Surface (Load to RAM)
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live toram quiet splash

LABEL normal
    MENU LABEL Debian Surface (Normal Boot)
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live quiet splash

LABEL debug
    MENU LABEL Debian Surface (Debug Mode)
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live debug
EOF
log_ok "isolinux configured"

# Setup UEFI boot (grub-efi)
log_head "Setting up UEFI Boot"
apt-get install -y grub-efi-amd64-bin mtools dosfstools

# Create EFI boot image
mkdir -p image/efi/boot
EFI_IMG="image/boot/grub/efi.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=4
mkfs.vfat "$EFI_IMG"
mmd -i "$EFI_IMG" ::/EFI ::/EFI/BOOT

# Create standalone GRUB EFI binary
grub-mkstandalone \
    --format=x86_64-efi \
    --output=image/efi/boot/bootx64.efi \
    --locales="" \
    --fonts="" \
    "boot/grub/grub.cfg=image/boot/grub/grub.cfg"

# Copy EFI binary to efi.img
mcopy -i "$EFI_IMG" image/efi/boot/bootx64.efi ::/EFI/BOOT/BOOTX64.EFI
log_ok "UEFI boot configured"

# Create ISO with both BIOS and UEFI support
log_head "Building ISO Image"
xorriso -as mkisofs \
    -o "$OUTPUT_DIR/$ISO_NAME" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot -isohybrid-gpt-basdat \
    -V "DEBIAN_SURFACE" \
    image

log_ok "ISO created: $OUTPUT_DIR/$ISO_NAME"

# Cleanup
log_head "Cleaning Up"
rm -rf "$BUILD_DIR"
log_ok "Build directory cleaned"

# Summary
log_head "Build Complete"
ls -lh "$OUTPUT_DIR/$ISO_NAME"
echo ""
echo "To use:"
echo "1. Copy to Ventoy USB: cp $ISO_NAME /mnt/ventoy/"
echo "2. Boot from USB, select 'Debian Surface Recovery'"
echo "3. System loads to RAM, USB can be removed"
echo ""
