#!/bin/bash
# Build Arch Linux Surface Live ISO
# Creates an Arch live image with Surface drivers, boots to RAM
#
# Usage: sudo ./build_live.sh
#
# Requirements: Run on Arch Linux system
# Output: arch-surface-live.iso (~1.2GB)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/tmp/arch-surface-live"
OUTPUT_DIR="$SCRIPT_DIR"
ISO_NAME="arch-surface-live.iso"
ARCHISO_PROFILE="/usr/share/archiso/configs/releng"

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

# Check if on Arch
if [ ! -f /etc/arch-release ]; then
    log_err "This script must be run on Arch Linux"
fi

# Check dependencies
log_head "Checking Dependencies"
for pkg in archiso; do
    if ! pacman -Q $pkg &>/dev/null; then
        log_info "Installing $pkg..."
        pacman -S --noconfirm $pkg
    fi
done
log_ok "All dependencies installed"

# Clean previous build
log_head "Preparing Build Environment"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cp -r "$ARCHISO_PROFILE" "$BUILD_DIR/profile"
cd "$BUILD_DIR/profile"
log_ok "Build directory ready: $BUILD_DIR/profile"

# Add linux-surface repo
log_head "Adding linux-surface Repository"
cat >> pacman.conf << 'EOF'

[linux-surface]
Server = https://pkg.surfacelinux.com/arch/
EOF
log_ok "linux-surface repo added"

# Import GPG key
log_info "Importing linux-surface GPG key..."
pacman-key --recv-keys 56C464BAAC421453
pacman-key --lsign-key 56C464BAAC421453
log_ok "GPG key imported"

# Add packages
log_head "Configuring Packages"
cat >> packages.x86_64 << 'EOF'

# Surface drivers
linux-surface
linux-surface-headers
iptsd

# Shells
fish
zsh

# Editors
vim
nano
neovim

# Network
networkmanager
iwd
openssh

# CLI tools
btop
htop
ripgrep
fd
fzf
jq
yq
tmux
neofetch
eza
bat
zoxide
curl
wget
git

# Development
nodejs
npm
python
python-pip

# GUI (minimal)
xorg-server
xorg-xinit
openbox
xterm
pcmanfm
lxappearance
mesa
ttf-dejavu
ttf-liberation

# Wayland (optional)
sway
foot
wofi

# Browser
lynx

# Disk tools
cryptsetup
btrfs-progs
dosfstools
e2fsprogs
parted
EOF
log_ok "Packages added"

# Remove stock linux kernel (we use linux-surface)
sed -i 's/^linux$/# linux (replaced by linux-surface)/' packages.x86_64
log_ok "Stock kernel commented out"

# Create user setup script
log_head "Creating User Configuration"
mkdir -p airootfs/root
cat > airootfs/root/customize_airootfs.sh << 'CUSTOMIZE_SCRIPT'
#!/bin/bash

# Enable services
systemctl enable NetworkManager
systemctl enable iptsd
systemctl enable sshd

# Create user
useradd -m -G wheel,video,input,audio -s /usr/bin/fish diego
echo "diego:1234567890" | chpasswd
echo "root:1234567890" | chpasswd

# Passwordless sudo
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

# Create xinitrc for openbox
echo "exec openbox-session" > /home/diego/.xinitrc
chown diego:diego /home/diego/.xinitrc

# Install Claude Code
npm install -g @anthropic-ai/claude-code || true

# Create welcome message
cat > /home/diego/.bash_profile << 'EOF'
echo ""
echo "=================================="
echo "  Arch Linux Surface Recovery"
echo "=================================="
echo ""
echo "Commands:"
echo "  startx     - Start Openbox GUI"
echo "  sway       - Start Sway (Wayland)"
echo "  nmtui      - WiFi configuration"
echo "  claude     - Claude Code CLI"
echo "  btop       - System monitor"
echo ""
neofetch --off 2>/dev/null || true
EOF
chown diego:diego /home/diego/.bash_profile

# Configure fish welcome
mkdir -p /home/diego/.config/fish
cat > /home/diego/.config/fish/config.fish << 'EOF'
if status is-interactive
    echo ""
    echo "  Arch Linux Surface Recovery"
    echo "  Commands: startx | sway | nmtui | claude | btop"
    echo ""
end
EOF
chown -R diego:diego /home/diego/.config

# Auto-login on tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin diego --noclear %I $TERM
EOF

echo "Customization complete!"
CUSTOMIZE_SCRIPT
chmod +x airootfs/root/customize_airootfs.sh
log_ok "User configuration script created"

# Configure bootloader for toram
log_head "Configuring Boot Options"
mkdir -p syslinux
cat >> syslinux/archiso_sys-linux.cfg << 'EOF'

LABEL arch_surface_toram
TEXT HELP
Boot Arch Linux Surface to RAM (USB can be removed after boot)
ENDTEXT
MENU LABEL Arch Linux Surface (copytoram)
LINUX /%INSTALL_DIR%/boot/x86_64/vmlinuz-linux-surface
INITRD /%INSTALL_DIR%/boot/x86_64/initramfs-linux-surface.img
APPEND archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% copytoram=y
EOF
log_ok "Boot options configured"

# Build ISO
log_head "Building ISO (this takes a while...)"
cd "$BUILD_DIR"
mkarchiso -v -w work -o out profile
log_ok "ISO built"

# Move ISO
mv out/*.iso "$OUTPUT_DIR/$ISO_NAME"
log_ok "ISO moved to: $OUTPUT_DIR/$ISO_NAME"

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
echo "2. Boot from USB, select 'Arch Linux Surface'"
echo "3. Choose 'copytoram' option to load to RAM"
echo ""
