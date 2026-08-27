#!/bin/bash
#===============================================================================
# Alpine Fallback ISO Builder
# Creates a minimal Alpine ISO with Claude CLI + lightweight desktop
#===============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="/tmp/alpine-fallback-build"
OUT_DIR="${SCRIPT_DIR}/dist"
ALPINE_VERSION="v3.21"
ALPINE_ARCH="x86_64"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

#===============================================================================
# PACKAGE LISTS
#===============================================================================

# Base system
BASE_PKGS="
alpine-base
alpine-conf
openrc
busybox
busybox-openrc
"

# Network & downloads
NET_PKGS="
curl
wget
ca-certificates
openssh
dhcpcd
wpa_supplicant
networkmanager
networkmanager-wifi
"

# Claude CLI requirements (Node.js based)
CLAUDE_PKGS="
nodejs
npm
git
bash
coreutils
grep
sed
"

# Openbox desktop
DESKTOP_PKGS="
xorg-server
xinit
xf86-video-vesa
xf86-video-fbdev
xf86-video-modesetting
xf86-input-libinput
openbox
obconf
ttf-dejavu
font-noto
dbus
dbus-openrc
elogind
elogind-openrc
polkit
polkit-openrc
mesa
mesa-dri-gallium
"

# Lightweight apps
APP_PKGS="
pcmanfm
falkon
lxterminal
feh
picom
tint2
"

# Shells
SHELL_PKGS="
zsh
zsh-vcs
fish
fish-tools
"

# Utilities
UTIL_PKGS="
htop
nano
vim
less
file
tar
gzip
xz
"

ALL_PKGS="${BASE_PKGS} ${NET_PKGS} ${CLAUDE_PKGS} ${DESKTOP_PKGS} ${APP_PKGS} ${SHELL_PKGS} ${UTIL_PKGS}"

#===============================================================================
# FUNCTIONS
#===============================================================================

setup_workdir() {
    log "Setting up work directory..."
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"/{aports,overlay,iso-out}
    mkdir -p "${OUT_DIR}"
}

clone_aports() {
    log "Cloning Alpine aports (scripts only)..."
    if [[ ! -d "${WORK_DIR}/aports/scripts" ]]; then
        git clone --depth 1 --filter=blob:none --sparse \
            https://gitlab.alpinelinux.org/alpine/aports.git \
            "${WORK_DIR}/aports"
        cd "${WORK_DIR}/aports"
        git sparse-checkout set scripts
    fi
}

create_profile() {
    log "Creating custom mkimage profile..."

    cat > "${WORK_DIR}/aports/scripts/mkimg.claude.sh" << 'PROFILE_EOF'
# Claude Fallback Desktop Profile

profile_claude() {
    profile_standard
    title="Alpine Claude Fallback"
    desc="Minimal Alpine with Claude CLI and lightweight desktop"
    arch="x86_64"
    kernel_flavors="lts"
    kernel_cmdline="nomodeset quiet"

    # All packages baked into ISO
    apks="$apks
        alpine-base alpine-conf openrc busybox busybox-openrc
        curl wget ca-certificates openssh dhcpcd
        wpa_supplicant networkmanager networkmanager-wifi
        nodejs npm git bash coreutils grep sed
        xorg-server xinit xf86-video-vesa xf86-video-fbdev
        xf86-video-modesetting xf86-input-libinput
        openbox obconf ttf-dejavu font-noto
        dbus dbus-openrc elogind elogind-openrc
        polkit polkit-openrc mesa mesa-dri-gallium
        pcmanfm falkon lxterminal feh picom tint2
        zsh zsh-vcs fish fish-tools
        htop nano vim less file tar gzip xz
    "

    apkovl="genapkovl-claude.sh"
}
PROFILE_EOF
}

create_overlay_generator() {
    log "Creating overlay generator..."

    cat > "${WORK_DIR}/aports/scripts/genapkovl-claude.sh" << 'OVERLAY_EOF'
#!/bin/sh

hostname="$1"
if [ -z "$hostname" ]; then
    hostname="alpine-claude"
fi

cleanup() {
    rm -rf "$tmp"
}

makefile() {
    OWNER="$1"
    PERMS="$2"
    FILENAME="$3"
    cat > "$FILENAME"
    chown "$OWNER" "$FILENAME"
    chmod "$PERMS" "$FILENAME"
}

rc_add() {
    mkdir -p "$tmp"/etc/runlevels/"$2"
    ln -sf /etc/init.d/"$1" "$tmp"/etc/runlevels/"$2"/"$1"
}

tmp="$(mktemp -d)"
trap cleanup EXIT

mkdir -p "$tmp"/etc/apk
mkdir -p "$tmp"/etc/network
mkdir -p "$tmp"/etc/local.d
mkdir -p "$tmp"/root
mkdir -p "$tmp"/home/user

#--- Repositories ---
cat > "$tmp"/etc/apk/repositories << EOF
http://dl-cdn.alpinelinux.org/alpine/v3.21/main
http://dl-cdn.alpinelinux.org/alpine/v3.21/community
EOF

#--- Hostname ---
echo "$hostname" > "$tmp"/etc/hostname

#--- Network ---
cat > "$tmp"/etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

#--- User setup script ---
makefile root:root 0755 "$tmp"/etc/local.d/setup-user.start << 'SETUP_EOF'
#!/bin/sh

# Create user if not exists
if ! id -u user >/dev/null 2>&1; then
    adduser -D -s /bin/bash -h /home/user user
    echo "user:user" | chpasswd
    addgroup user wheel
    addgroup user video
    addgroup user audio
    addgroup user input
fi

# Setup .xinitrc for user
cat > /home/user/.xinitrc << 'XINITRC'
#!/bin/sh
# Start compositor
picom -b &

# Start panel
tint2 &

# Set wallpaper (solid color fallback)
xsetroot -solid "#2e3440"

# Start Openbox
exec openbox-session
XINITRC
chmod +x /home/user/.xinitrc
chown user:user /home/user/.xinitrc

# Openbox autostart
mkdir -p /home/user/.config/openbox
cat > /home/user/.config/openbox/autostart << 'AUTOSTART'
# Autostart apps
lxterminal &
AUTOSTART
chown -R user:user /home/user/.config

# Install Claude CLI globally
if command -v npm >/dev/null 2>&1; then
    npm install -g @anthropic-ai/claude-code 2>/dev/null || true
fi

# Auto-login hint
echo ""
echo "==================================="
echo " Alpine Claude Fallback Desktop"
echo "==================================="
echo " User: user / Password: user"
echo " Root: root / Password: root"
echo ""
echo " To start desktop: startx"
echo " To run Claude: claude"
echo "==================================="
SETUP_EOF

#--- Root password ---
makefile root:root 0755 "$tmp"/etc/local.d/root-pw.start << 'ROOTPW_EOF'
#!/bin/sh
echo "root:root" | chpasswd
ROOTPW_EOF

#--- Openbox menu ---
mkdir -p "$tmp"/etc/xdg/openbox
cat > "$tmp"/etc/xdg/openbox/menu.xml << 'MENU_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
<menu id="root-menu" label="Openbox">
  <item label="Terminal"><action name="Execute"><execute>lxterminal</execute></action></item>
  <item label="File Manager"><action name="Execute"><execute>pcmanfm</execute></action></item>
  <item label="Browser"><action name="Execute"><execute>falkon</execute></action></item>
  <separator />
  <item label="Claude CLI"><action name="Execute"><execute>lxterminal -e claude</execute></action></item>
  <separator />
  <item label="Reconfigure"><action name="Reconfigure" /></item>
  <item label="Exit"><action name="Exit" /></item>
</menu>
</openbox_menu>
MENU_EOF

#--- Enable services ---
rc_add devfs sysinit
rc_add dmesg sysinit
rc_add mdev sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit

rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot
rc_add networking boot

rc_add dbus default
rc_add elogind default
rc_add networkmanager default
rc_add local default

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

tar -c -C "$tmp" . | gzip -9n
OVERLAY_EOF

    chmod +x "${WORK_DIR}/aports/scripts/genapkovl-claude.sh"
}

build_iso() {
    log "Building ISO with mkimage.sh..."

    cd "${WORK_DIR}/aports/scripts"

    # Make sure scripts are executable
    chmod +x mkimage.sh genapkovl-claude.sh

    ./mkimage.sh \
        --tag "${ALPINE_VERSION}" \
        --outdir "${WORK_DIR}/iso-out" \
        --arch "${ALPINE_ARCH}" \
        --repository "http://dl-cdn.alpinelinux.org/alpine/${ALPINE_VERSION}/main" \
        --repository "http://dl-cdn.alpinelinux.org/alpine/${ALPINE_VERSION}/community" \
        --profile claude

    # Copy output
    cp "${WORK_DIR}/iso-out"/*.iso "${OUT_DIR}/" 2>/dev/null || true

    log "ISO built successfully!"
    ls -lh "${OUT_DIR}"/*.iso 2>/dev/null
}

clean() {
    log "Cleaning up..."
    rm -rf "${WORK_DIR}"
}

show_help() {
    cat << EOF
Alpine Claude Fallback ISO Builder

Usage: $0 [command]

Commands:
    build       Build the ISO (default)
    clean       Clean work directory
    help        Show this help

Packages included:
    - Claude CLI (via npm)
    - Openbox window manager
    - Falkon browser (lightweight Qt)
    - PCManFM file manager (like Dolphin but lighter)
    - LXTerminal
    - Shells: bash, zsh, fish
    - curl, wget, git
    - NetworkManager

Output: ${OUT_DIR}/

EOF
}

#===============================================================================
# MAIN
#===============================================================================

case "${1:-build}" in
    build)
        setup_workdir
        clone_aports
        create_profile
        create_overlay_generator
        build_iso
        log "Done! ISO is in ${OUT_DIR}/"
        ;;
    clean)
        clean
        log "Cleaned."
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        err "Unknown command: $1"
        ;;
esac
