#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                      TOOLS MINIMUM - Plain Install                         ║
# ║                                                                            ║
# ║   Install tools directly on host (no container isolation)                 ║
# ║   For container install: use docker-compose.yml or podman-compose.yml     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   ./install.sh              # Install all tools
#   ./install.sh --minimal    # Install only CLI tools (no GUI)
#   ./install.sh --check      # Check what's already installed
#   ./install.sh --uninstall  # Remove installed tools
#
# Supported distros: Arch, Fedora, Debian/Ubuntu

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[-]${NC} %s\n" "$1"; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════
# PACKAGE LISTS
# ═══════════════════════════════════════════════════════════════════════════

# CLI tools (always installed)
CLI_PACKAGES_ARCH="base-devel git sudo curl wget bash coreutils findutils grep sed less htop jq vim unzip xclip iproute2 iputils openssh ca-certificates"
CLI_PACKAGES_FEDORA="@development-tools git sudo curl wget bash coreutils findutils grep sed less htop jq vim unzip xclip iproute openssh ca-certificates"
CLI_PACKAGES_DEBIAN="build-essential git sudo curl wget bash coreutils findutils grep sed less htop jq vim unzip xclip iproute2 iputils-ping openssh-client ca-certificates"

# Privacy tools
PRIVACY_PACKAGES_ARCH="tor torsocks dnscrypt-proxy wireguard-tools"
PRIVACY_PACKAGES_FEDORA="tor torsocks dnscrypt-proxy wireguard-tools"
PRIVACY_PACKAGES_DEBIAN="tor torsocks dnscrypt-proxy wireguard-tools"

# Languages & compilers
LANG_PACKAGES_ARCH="nodejs npm python python-pip python-pipx rust"
LANG_PACKAGES_FEDORA="nodejs npm python3 python3-pip pipx rust cargo"
LANG_PACKAGES_DEBIAN="nodejs npm python3 python3-pip pipx rustc cargo"

# GUI apps (optional)
GUI_PACKAGES_ARCH="konsole falkon dolphin okular breeze-icons ttf-dejavu"
GUI_PACKAGES_FEDORA="konsole5 falkon dolphin okular breeze-icon-theme dejavu-fonts-all"
GUI_PACKAGES_DEBIAN="konsole falkon dolphin okular breeze-icon-theme fonts-dejavu"

# ═══════════════════════════════════════════════════════════════════════════
# DETECT DISTRO
# ═══════════════════════════════════════════════════════════════════════════

detect_distro() {
    if [ -f /etc/arch-release ]; then
        DISTRO="arch"
        PKG_INSTALL="sudo pacman -S --noconfirm"
        PKG_UPDATE="sudo pacman -Syu --noconfirm"
        PKG_REMOVE="sudo pacman -Rns --noconfirm"
        PKG_CHECK="pacman -Q"
    elif [ -f /etc/fedora-release ]; then
        DISTRO="fedora"
        PKG_INSTALL="sudo dnf install -y"
        PKG_UPDATE="sudo dnf update -y"
        PKG_REMOVE="sudo dnf remove -y"
        PKG_CHECK="rpm -q"
    elif [ -f /etc/debian_version ]; then
        DISTRO="debian"
        PKG_INSTALL="sudo apt-get install -y"
        PKG_UPDATE="sudo apt-get update && sudo apt-get upgrade -y"
        PKG_REMOVE="sudo apt-get remove -y"
        PKG_CHECK="dpkg -l"
    else
        error "Unsupported distribution"
    fi
    log "Detected: $DISTRO"
}

# ═══════════════════════════════════════════════════════════════════════════
# INSTALL FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

install_cli() {
    log "Installing CLI tools..."
    case "$DISTRO" in
        arch)   $PKG_INSTALL $CLI_PACKAGES_ARCH ;;
        fedora) $PKG_INSTALL $CLI_PACKAGES_FEDORA ;;
        debian) $PKG_INSTALL $CLI_PACKAGES_DEBIAN ;;
    esac
}

install_privacy() {
    log "Installing privacy tools..."
    case "$DISTRO" in
        arch)   $PKG_INSTALL $PRIVACY_PACKAGES_ARCH ;;
        fedora) $PKG_INSTALL $PRIVACY_PACKAGES_FEDORA ;;
        debian) $PKG_INSTALL $PRIVACY_PACKAGES_DEBIAN ;;
    esac

    # Configure dnscrypt-proxy
    log "Configuring dnscrypt-proxy..."
    sudo mkdir -p /etc/dnscrypt-proxy
    cat << 'EOF' | sudo tee /etc/dnscrypt-proxy/dnscrypt-proxy.toml > /dev/null
server_names = ['cloudflare', 'cloudflare-ipv6']
listen_addresses = ['127.0.0.1:53']
EOF
}

install_languages() {
    log "Installing languages & compilers..."
    case "$DISTRO" in
        arch)   $PKG_INSTALL $LANG_PACKAGES_ARCH ;;
        fedora) $PKG_INSTALL $LANG_PACKAGES_FEDORA ;;
        debian) $PKG_INSTALL $LANG_PACKAGES_DEBIAN ;;
    esac
}

install_ai_tools() {
    log "Installing AI CLI tools..."
    if command -v npm >/dev/null 2>&1; then
        sudo npm install -g @anthropic-ai/claude-code || warn "Failed to install claude-code"
        sudo npm install -g @google/gemini-cli || warn "Failed to install gemini-cli"
    else
        warn "npm not found, skipping AI tools"
    fi
}

install_gui() {
    log "Installing GUI applications..."
    case "$DISTRO" in
        arch)   $PKG_INSTALL $GUI_PACKAGES_ARCH ;;
        fedora) $PKG_INSTALL $GUI_PACKAGES_FEDORA ;;
        debian) $PKG_INSTALL $GUI_PACKAGES_DEBIAN ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# CHECK FUNCTION
# ═══════════════════════════════════════════════════════════════════════════

check_installed() {
    log "Checking installed tools..."

    printf "\n${CYAN}CLI Tools:${NC}\n"
    for pkg in git curl wget vim htop jq; do
        if command -v "$pkg" >/dev/null 2>&1; then
            printf "  ${GREEN}[x]${NC} %s\n" "$pkg"
        else
            printf "  ${RED}[ ]${NC} %s\n" "$pkg"
        fi
    done

    printf "\n${CYAN}Privacy Tools:${NC}\n"
    for pkg in tor dnscrypt-proxy wg; do
        if command -v "$pkg" >/dev/null 2>&1; then
            printf "  ${GREEN}[x]${NC} %s\n" "$pkg"
        else
            printf "  ${RED}[ ]${NC} %s\n" "$pkg"
        fi
    done

    printf "\n${CYAN}Languages:${NC}\n"
    for pkg in node python3 rustc cargo; do
        if command -v "$pkg" >/dev/null 2>&1; then
            printf "  ${GREEN}[x]${NC} %s\n" "$pkg"
        else
            printf "  ${RED}[ ]${NC} %s\n" "$pkg"
        fi
    done

    printf "\n${CYAN}AI Tools:${NC}\n"
    for pkg in claude gemini; do
        if command -v "$pkg" >/dev/null 2>&1; then
            printf "  ${GREEN}[x]${NC} %s\n" "$pkg"
        else
            printf "  ${RED}[ ]${NC} %s\n" "$pkg"
        fi
    done

    printf "\n${CYAN}GUI Apps:${NC}\n"
    for pkg in konsole falkon dolphin okular; do
        if command -v "$pkg" >/dev/null 2>&1; then
            printf "  ${GREEN}[x]${NC} %s\n" "$pkg"
        else
            printf "  ${RED}[ ]${NC} %s\n" "$pkg"
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

main() {
    printf "${CYAN}"
    printf "╔═══════════════════════════════════════════════════════════════╗\n"
    printf "║              TOOLS MINIMUM - Plain Install                    ║\n"
    printf "╚═══════════════════════════════════════════════════════════════╝${NC}\n"

    detect_distro

    case "${1:-}" in
        --check)
            check_installed
            ;;
        --minimal)
            log "Installing minimal (CLI only)..."
            $PKG_UPDATE
            install_cli
            install_privacy
            install_languages
            install_ai_tools
            log "Done! Minimal tools installed."
            ;;
        --uninstall)
            warn "Uninstall not implemented - remove packages manually"
            ;;
        *)
            log "Installing all tools (CLI + GUI)..."
            $PKG_UPDATE
            install_cli
            install_privacy
            install_languages
            install_ai_tools
            install_gui
            log "Done! All tools installed."
            ;;
    esac
}

main "$@"
