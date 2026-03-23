#!/bin/bash
# Arch Linux Surface - Setup Script
# Usage: ./install.sh [scan|install|surface|desktop|help]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/install.json"
LOGFILE="$SCRIPT_DIR/install_log.md"
CHECKFILE="$SCRIPT_DIR/install_check.md"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

###################
# HELPER FUNCTIONS
###################

usage() {
    echo ""
    echo "Arch Linux Surface - Setup Script"
    echo ""
    echo "Usage: ./install.sh [command]"
    echo ""
    echo "Commands:"
    echo "  surface   Install linux-surface drivers (DO THIS FIRST!)"
    echo "  scan      Check packages, output install_check.md"
    echo "  install   Install missing packages and configure"
    echo "  desktop   Start Openbox desktop (startx)"
    echo "  sway      Start Sway (Wayland)"
    echo "  help      Show this help message"
    echo ""
    echo "Recommended order:"
    echo "  1. ./install.sh surface   # Install Surface drivers, then REBOOT"
    echo "  2. ./install.sh scan      # Check what's missing"
    echo "  3. ./install.sh install   # Install everything"
    echo "  4. ./install.sh desktop   # Start GUI"
    echo ""
    echo "Config: $CONFIG"
    echo ""
    exit 0
}

log_ok()   { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
log_miss() { printf "${RED}[MISS]${NC} %s\n" "$1"; }
log_info() { printf "${YELLOW}[INFO]${NC} %s\n" "$1"; }
log_head() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
log_err()  { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }

check_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Installing jq..."
        sudo pacman -S --noconfirm jq
    fi
}

check_config() {
    if [ ! -f "$CONFIG" ]; then
        log_err "$CONFIG not found"
    fi
}

# Sudo check
SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

###################
# SURFACE COMMAND
###################

cmd_surface() {
    log_head "Installing linux-surface Drivers"

    # Check if already installed
    if pacman -Q linux-surface &>/dev/null; then
        log_ok "linux-surface already installed"
        if lsmod | grep -q "surface_hid"; then
            log_ok "Surface keyboard driver loaded!"
        else
            log_info "Reboot required for Surface keyboard to work"
        fi
        return 0
    fi

    # Add linux-surface repo
    if ! grep -q "linux-surface" /etc/pacman.conf 2>/dev/null; then
        log_info "Adding linux-surface repository..."
        $SUDO tee -a /etc/pacman.conf > /dev/null << 'EOF'

[linux-surface]
Server = https://pkg.surfacelinux.com/arch/
EOF
    fi

    # Import GPG key
    log_info "Importing GPG key..."
    $SUDO pacman-key --recv-keys 56C464BAAC421453
    $SUDO pacman-key --lsign-key 56C464BAAC421453

    # Update and install
    log_info "Installing linux-surface kernel..."
    $SUDO pacman -Syu --noconfirm
    $SUDO pacman -S --noconfirm linux-surface linux-surface-headers iptsd

    # Enable iptsd
    log_info "Enabling iptsd (touchscreen)..."
    $SUDO systemctl enable iptsd

    log_ok "linux-surface installed!"
    echo ""
    echo "========================================"
    echo "  REBOOT NOW for keyboard to work!"
    echo "  Run: sudo reboot"
    echo "========================================"
    echo ""

    # Log
    echo "- $(date '+%Y-%m-%d %H:%M'): linux-surface installed" >> "$LOGFILE"
}

###################
# SCAN COMMAND
###################

cmd_scan() {
    check_jq
    check_config

    log_head "Scanning Packages"

    # Start check file
    cat > "$CHECKFILE" << EOF
# Arch Linux Surface - Package Check

> Generated: $(date '+%Y-%m-%d %H:%M:%S')
> Config: $CONFIG

---

EOF

    # Surface drivers first
    echo "## Surface Drivers" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"

    for pkg in linux-surface linux-surface-headers iptsd; do
        if pacman -Q "$pkg" &>/dev/null; then
            log_ok "$pkg"
            echo "- [x] $pkg" >> "$CHECKFILE"
        else
            log_miss "$pkg"
            echo "- [ ] $pkg" >> "$CHECKFILE"
        fi
    done
    echo "" >> "$CHECKFILE"

    # Pacman packages
    echo "## Pacman Packages" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"

    INSTALLED=0
    MISSING=0

    for category in base shells editors network graphics wayland browsers monitors dev utils cli_tools gui_apps; do
        PKGS=$(jq -r ".pacman.$category // [] | .[]" "$CONFIG" 2>/dev/null)
        if [ -n "$PKGS" ]; then
            echo "### $category" >> "$CHECKFILE"
            for pkg in $PKGS; do
                if pacman -Q "$pkg" &>/dev/null; then
                    log_ok "$pkg"
                    echo "- [x] $pkg" >> "$CHECKFILE"
                    INSTALLED=$((INSTALLED + 1))
                else
                    log_miss "$pkg"
                    echo "- [ ] $pkg" >> "$CHECKFILE"
                    MISSING=$((MISSING + 1))
                fi
            done
            echo "" >> "$CHECKFILE"
        fi
    done

    # NPM packages
    echo "## NPM Packages" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"

    NPM_PKGS=$(jq -r '.npm.global // [] | .[]' "$CONFIG" 2>/dev/null)
    for pkg in $NPM_PKGS; do
        if npm list -g "$pkg" &>/dev/null; then
            log_ok "$pkg (npm)"
            echo "- [x] $pkg" >> "$CHECKFILE"
        else
            log_miss "$pkg (npm)"
            echo "- [ ] $pkg" >> "$CHECKFILE"
            MISSING=$((MISSING + 1))
        fi
    done

    # Summary
    echo "" >> "$CHECKFILE"
    echo "---" >> "$CHECKFILE"
    echo "## Summary" >> "$CHECKFILE"
    echo "- Installed: $INSTALLED" >> "$CHECKFILE"
    echo "- Missing: $MISSING" >> "$CHECKFILE"

    log_head "Scan Complete"
    log_info "Installed: $INSTALLED"
    log_info "Missing: $MISSING"
    log_info "Details: $CHECKFILE"
}

###################
# INSTALL COMMAND
###################

cmd_install() {
    check_jq
    check_config

    # Check Surface drivers first
    if ! pacman -Q linux-surface &>/dev/null; then
        log_err "linux-surface not installed! Run: ./install.sh surface"
    fi

    log_head "Installing Packages"

    # All pacman packages
    ALL_PKGS=""
    for category in base shells editors network graphics wayland browsers monitors dev utils cli_tools gui_apps; do
        PKGS=$(jq -r ".pacman.$category // [] | .[]" "$CONFIG" 2>/dev/null)
        ALL_PKGS="$ALL_PKGS $PKGS"
    done

    log_info "Installing pacman packages..."
    $SUDO pacman -S --noconfirm --needed $ALL_PKGS

    # NPM packages
    NPM_PKGS=$(jq -r '.npm.global // [] | .[]' "$CONFIG" 2>/dev/null)
    if [ -n "$NPM_PKGS" ]; then
        log_info "Installing npm packages..."
        for pkg in $NPM_PKGS; do
            $SUDO npm install -g "$pkg" || log_info "npm: $pkg failed (may already exist)"
        done
    fi

    # Enable services
    log_info "Enabling services..."
    SERVICES=$(jq -r '.services.enable // [] | .[]' "$CONFIG" 2>/dev/null)
    for svc in $SERVICES; do
        $SUDO systemctl enable "$svc" 2>/dev/null || true
        $SUDO systemctl start "$svc" 2>/dev/null || true
        log_ok "Service: $svc"
    done

    # Create mount points
    log_info "Creating mount points..."
    $SUDO mkdir -p /mnt/pool /mnt/kubuntu

    # Setup user
    if ! id diego &>/dev/null; then
        log_info "Creating user diego..."
        $SUDO useradd -m -G wheel,video,input -s /usr/bin/fish diego
        echo "diego:1234567890" | $SUDO chpasswd
        log_ok "User diego created (password: 1234567890)"
    fi

    # Passwordless sudo
    if ! grep -q "NOPASSWD" /etc/sudoers 2>/dev/null; then
        echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" | $SUDO tee -a /etc/sudoers > /dev/null
        log_ok "Passwordless sudo enabled"
    fi

    # Create .xinitrc
    if [ ! -f ~/.xinitrc ]; then
        echo "exec openbox-session" > ~/.xinitrc
        log_ok "Created ~/.xinitrc"
    fi

    # Log
    echo "- $(date '+%Y-%m-%d %H:%M'): Full install completed" >> "$LOGFILE"

    log_head "Install Complete"
    log_info "Start GUI: ./install.sh desktop"
}

###################
# DESKTOP COMMANDS
###################

cmd_desktop() {
    log_head "Starting Openbox Desktop"

    # Check if startx exists
    if ! command -v startx >/dev/null 2>&1; then
        log_err "startx not found! Install xorg-xinit first:"
        echo "  sudo pacman -S xorg-xinit xorg-server openbox xterm"
        echo ""
        echo "If network is down, connect WiFi first:"
        echo "  nmtui"
        exit 1
    fi

    if [ ! -f ~/.xinitrc ]; then
        echo "exec openbox-session" > ~/.xinitrc
    fi
    startx
}

cmd_sway() {
    log_head "Starting Sway (Wayland)"
    sway
}

###################
# MAIN
###################

case "${1:-help}" in
    surface)  cmd_surface ;;
    scan)     cmd_scan ;;
    install)  cmd_install ;;
    desktop)  cmd_desktop ;;
    sway)     cmd_sway ;;
    help|*)   usage ;;
esac
