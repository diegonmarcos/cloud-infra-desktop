#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# B_APPS Host Installer
# Installs packages directly on host (no containers)
# Usage: ./install.sh [min|basic]
# ═══════════════════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:-min}"
JSON_FILE="$SCRIPT_DIR/${PROFILE}.json"

# ─────────────────────────────────────────────────────────────────────────────
# Colors
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# Detect distro
# ─────────────────────────────────────────────────────────────────────────────
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            arch|manjaro|endeavouros)
                echo "arch"
                ;;
            fedora|rhel|centos|rocky|alma)
                echo "fedora"
                ;;
            debian|ubuntu|linuxmint|pop)
                echo "debian"
                ;;
            *)
                log_error "Unsupported distro: $ID"
                exit 1
                ;;
        esac
    else
        log_error "Cannot detect distro"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Check dependencies
# ─────────────────────────────────────────────────────────────────────────────
check_deps() {
    if ! command -v jq &> /dev/null; then
        log_warn "jq not found, installing..."
        case "$DISTRO" in
            arch)   sudo pacman -S --noconfirm jq ;;
            fedora) sudo dnf install -y jq ;;
            debian) sudo apt install -y jq ;;
        esac
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Install system packages
# ─────────────────────────────────────────────────────────────────────────────
install_packages() {
    local packages
    packages=$(jq -r ".packages.$DISTRO[]" "$JSON_FILE" | tr '\n' ' ')

    log_info "Installing system packages for $DISTRO..."

    case "$DISTRO" in
        arch)
            sudo pacman -Syu --noconfirm
            sudo pacman -S --noconfirm --needed $packages
            ;;
        fedora)
            sudo dnf upgrade -y
            sudo dnf install -y $packages
            ;;
        debian)
            sudo apt update
            sudo apt upgrade -y
            sudo apt install -y $packages
            ;;
    esac

    log_ok "System packages installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# Install npm global packages
# ─────────────────────────────────────────────────────────────────────────────
install_npm() {
    local packages
    packages=$(jq -r '.npm[]' "$JSON_FILE" 2>/dev/null | tr '\n' ' ')

    if [ -n "$packages" ] && command -v npm &> /dev/null; then
        log_info "Installing npm global packages..."
        sudo npm install -g $packages || log_warn "Some npm packages failed"
        log_ok "npm packages installed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Install pip packages
# ─────────────────────────────────────────────────────────────────────────────
install_pip() {
    local packages
    packages=$(jq -r '.pip[]' "$JSON_FILE" 2>/dev/null | tr '\n' ' ')

    if [ -n "$packages" ]; then
        log_info "Installing pip packages..."
        pip install --break-system-packages $packages || \
        pip install $packages || \
        log_warn "Some pip packages failed"
        log_ok "pip packages installed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
main() {
    echo "═══════════════════════════════════════════════════════════════════"
    echo " B_APPS Host Installer - Profile: $PROFILE"
    echo "═══════════════════════════════════════════════════════════════════"

    # Validate
    if [ ! -f "$JSON_FILE" ]; then
        log_error "Profile not found: $JSON_FILE"
        log_info "Available profiles: min, basic"
        exit 1
    fi

    # Detect distro
    DISTRO=$(detect_distro)
    log_info "Detected distro: $DISTRO"

    # Check for jq
    check_deps

    # Install
    install_packages
    install_npm
    install_pip

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    log_ok "Installation complete!"
    echo "═══════════════════════════════════════════════════════════════════"
}

main "$@"
