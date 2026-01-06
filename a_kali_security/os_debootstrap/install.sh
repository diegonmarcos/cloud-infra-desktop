#!/bin/bash
# Kali Linux Surface - Setup Script
# Usage: ./install.sh [scan|install|surface|kali|desktop|help]

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
    echo "Kali Linux Surface - Setup Script"
    echo ""
    echo "Usage: ./install.sh [command]"
    echo ""
    echo "Commands:"
    echo "  surface   Verify/install linux-surface drivers"
    echo "  scan      Check packages, output install_check.md"
    echo "  install   Install base packages and configure"
    echo "  kali      Install Kali security tools"
    echo "  desktop   Start Openbox desktop (startx)"
    echo "  sway      Start Sway (Wayland)"
    echo "  help      Show this help message"
    echo ""
    echo "Recommended order:"
    echo "  1. ./install.sh surface   # Verify Surface drivers"
    echo "  2. ./install.sh scan      # Check what's missing"
    echo "  3. ./install.sh install   # Install base packages"
    echo "  4. ./install.sh kali      # Install security tools"
    echo "  5. ./install.sh desktop   # Start GUI"
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
        sudo apt-get install -y jq
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
    log_head "Checking linux-surface Drivers"

    # Check if kernel is installed
    if dpkg -l | grep -q "linux-image-surface"; then
        log_ok "linux-image-surface installed"
    else
        log_miss "linux-image-surface not installed"
        log_info "Installing linux-surface..."

        # Add repo if not present
        if [ ! -f /etc/apt/sources.list.d/linux-surface.list ]; then
            wget -qO - https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc \
                | gpg --dearmor | $SUDO tee /etc/apt/trusted.gpg.d/linux-surface.gpg > /dev/null
            echo "deb [arch=amd64] https://pkg.surfacelinux.com/debian release main" \
                | $SUDO tee /etc/apt/sources.list.d/linux-surface.list
            $SUDO apt-get update
        fi

        $SUDO apt-get install -y linux-image-surface linux-headers-surface iptsd
        $SUDO systemctl enable iptsd

        log_ok "linux-surface installed!"
        echo ""
        echo "========================================"
        echo "  REBOOT NOW for keyboard to work!"
        echo "  Run: sudo reboot"
        echo "========================================"
        return
    fi

    # Check iptsd
    if dpkg -l | grep -q "iptsd"; then
        log_ok "iptsd installed"
    else
        log_miss "iptsd not installed"
        $SUDO apt-get install -y iptsd
        $SUDO systemctl enable iptsd
    fi

    # Check modules
    if lsmod | grep -q "surface_aggregator"; then
        log_ok "surface_aggregator module loaded"
    else
        log_info "surface_aggregator not loaded (may need reboot)"
    fi

    if lsmod | grep -q "surface_hid"; then
        log_ok "surface_hid (keyboard) module loaded"
    else
        log_info "surface_hid not loaded (may need reboot)"
    fi

    # Check iptsd service
    if systemctl is-active --quiet iptsd 2>/dev/null; then
        log_ok "iptsd service running"
    else
        log_info "iptsd service not running"
    fi

    # Log
    echo "- $(date '+%Y-%m-%d %H:%M'): Surface check completed" >> "$LOGFILE"
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
# Kali Linux Surface - Package Check

> Generated: $(date '+%Y-%m-%d %H:%M:%S')
> Config: $CONFIG

---

EOF

    # Surface drivers first
    echo "## Surface Drivers" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"

    for pkg in linux-image-surface linux-headers-surface iptsd; do
        if dpkg -l | grep -q "^ii  $pkg"; then
            log_ok "$pkg"
            echo "- [x] $pkg" >> "$CHECKFILE"
        else
            log_miss "$pkg"
            echo "- [ ] $pkg" >> "$CHECKFILE"
        fi
    done
    echo "" >> "$CHECKFILE"

    # APT packages
    echo "## APT Packages" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"

    INSTALLED=0
    MISSING=0

    for category in base shells editors network graphics wayland browsers monitors dev utils cli_tools gui_apps; do
        PKGS=$(jq -r ".apt.$category // [] | .[]" "$CONFIG" 2>/dev/null)
        if [ -n "$PKGS" ]; then
            echo "### $category" >> "$CHECKFILE"
            for pkg in $PKGS; do
                if dpkg -l | grep -q "^ii  $pkg"; then
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

    # Kali tools
    echo "## Kali Security Tools" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"

    KALI_PKGS=$(jq -r '.apt.kali_tools // [] | .[]' "$CONFIG" 2>/dev/null)
    for pkg in $KALI_PKGS; do
        if dpkg -l | grep -q "^ii  $pkg"; then
            log_ok "$pkg (kali)"
            echo "- [x] $pkg" >> "$CHECKFILE"
        else
            log_miss "$pkg (kali)"
            echo "- [ ] $pkg" >> "$CHECKFILE"
            MISSING=$((MISSING + 1))
        fi
    done
    echo "" >> "$CHECKFILE"

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

    log_head "Installing Base Packages"

    # Update first
    log_info "Updating package lists..."
    $SUDO apt-get update

    # All apt packages (except kali_tools)
    ALL_PKGS=""
    for category in base shells editors network graphics wayland browsers monitors dev utils cli_tools gui_apps; do
        PKGS=$(jq -r ".apt.$category // [] | .[]" "$CONFIG" 2>/dev/null)
        ALL_PKGS="$ALL_PKGS $PKGS"
    done

    log_info "Installing apt packages..."
    $SUDO apt-get install -y $ALL_PKGS || {
        log_info "Some packages failed, trying individually..."
        for pkg in $ALL_PKGS; do
            $SUDO apt-get install -y "$pkg" 2>/dev/null || log_info "Skipped: $pkg"
        done
    }

    # NPM packages
    NPM_PKGS=$(jq -r '.npm.global // [] | .[]' "$CONFIG" 2>/dev/null)
    if [ -n "$NPM_PKGS" ] && command -v npm &>/dev/null; then
        log_info "Installing npm packages..."
        for pkg in $NPM_PKGS; do
            $SUDO npm install -g "$pkg" 2>/dev/null || log_info "npm: $pkg failed"
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

    # Passwordless sudo for user
    if [ -n "$USER" ] && [ "$USER" != "root" ]; then
        if ! grep -q "$USER.*NOPASSWD" /etc/sudoers.d/* 2>/dev/null; then
            echo "$USER ALL=(ALL) NOPASSWD: ALL" | $SUDO tee /etc/sudoers.d/$USER > /dev/null
            log_ok "Passwordless sudo enabled for $USER"
        fi
    fi

    # Create .xinitrc
    if [ ! -f ~/.xinitrc ]; then
        echo "exec openbox-session" > ~/.xinitrc
        log_ok "Created ~/.xinitrc"
    fi

    # Log
    echo "- $(date '+%Y-%m-%d %H:%M'): Base install completed" >> "$LOGFILE"

    log_head "Base Install Complete"
    log_info "Run: ./install.sh kali  # For security tools"
}

###################
# KALI TOOLS COMMAND
###################

cmd_kali() {
    check_jq
    check_config

    log_head "Installing Kali Security Tools"

    log_info "This may take a while..."

    # Kali core first
    log_info "Installing kali-linux-core..."
    $SUDO apt-get install -y kali-linux-core || log_info "kali-linux-core skipped"

    # Individual tools
    KALI_PKGS=$(jq -r '.apt.kali_tools // [] | .[]' "$CONFIG" 2>/dev/null)

    log_info "Installing security tools..."
    for pkg in $KALI_PKGS; do
        log_info "Installing $pkg..."
        $SUDO apt-get install -y "$pkg" 2>/dev/null || log_info "Skipped: $pkg"
    done

    # Log
    echo "- $(date '+%Y-%m-%d %H:%M'): Kali tools installed" >> "$LOGFILE"

    log_head "Kali Tools Install Complete"
    log_info "Tools installed: nmap, wireshark, metasploit, etc."
}

###################
# DESKTOP COMMANDS
###################

cmd_desktop() {
    log_head "Starting Openbox Desktop"
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
    kali)     cmd_kali ;;
    desktop)  cmd_desktop ;;
    sway)     cmd_sway ;;
    help|*)   usage ;;
esac
