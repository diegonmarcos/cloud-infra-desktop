#!/bin/bash
# Build NixOS Surface Slim ISO
#
# Usage:
#   ./build.sh         - Build ISO
#   ./build.sh vm      - Build and run VM for testing
#   ./build.sh raw     - Build raw disk image
#   ./build.sh clean   - Clean build artifacts

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

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

build_iso() {
    log_head "Building NixOS Surface Slim ISO"

    # Check nix is available
    if ! command -v nix &>/dev/null; then
        log_err "Nix is not installed. Install with: curl -L https://nixos.org/nix/install | sh"
    fi

    log_info "Building ISO (this may take 10-30 minutes on first build)..."

    nix build .#iso \
        --extra-experimental-features "nix-command flakes" \
        --out-link result

    if [ -L result ]; then
        ISO_PATH=$(readlink -f result)/iso/*.iso
        ISO_SIZE=$(du -h $ISO_PATH | cut -f1)
        log_ok "ISO built: $ISO_PATH"
        log_ok "Size: $ISO_SIZE"

        # Copy to current directory
        cp $ISO_PATH ./nixos-surface-slim.iso
        log_ok "Copied to: ./nixos-surface-slim.iso"

        echo ""
        echo "To use with Ventoy:"
        echo "  cp nixos-surface-slim.iso /path/to/ventoy/usb/"
    else
        log_err "Build failed - no result link created"
    fi
}

build_vm() {
    log_head "Building NixOS Surface VM for testing"

    nix build .#vm \
        --extra-experimental-features "nix-command flakes" \
        --out-link result-vm

    log_ok "VM built. Run with:"
    echo "  ./result-vm/bin/run-*-vm"
}

build_raw() {
    log_head "Building Raw Disk Image"

    nix build .#raw \
        --extra-experimental-features "nix-command flakes" \
        --out-link result-raw

    log_ok "Raw image built: $(readlink -f result-raw)"
}

clean() {
    log_head "Cleaning build artifacts"
    rm -f result result-vm result-raw
    rm -f *.iso
    log_ok "Cleaned"
}

check_flake() {
    log_head "Checking flake syntax"
    nix flake check \
        --extra-experimental-features "nix-command flakes" \
        --no-build
    log_ok "Flake syntax OK"
}

show_info() {
    echo ""
    echo "NixOS Surface Slim - Ultra-Minimal USB Recovery"
    echo "================================================"
    echo ""
    echo "Features:"
    echo "  - Surface Pro hardware (linux-surface kernel via nixos-hardware)"
    echo "  - Openbox GUI (startx, no display manager)"
    echo "  - Fish shell + CLI tools (btop, ripgrep, fzf)"
    echo "  - Node.js + Claude Code (npx wrapper)"
    echo "  - WiFi GUI (nm-connection-editor)"
    echo "  - LUKS/btrfs recovery tools"
    echo ""
    echo "Credentials:"
    echo "  User: diego / root"
    echo "  Password: 1234567890"
    echo ""
    echo "After boot:"
    echo "  1. Auto-login to console as diego"
    echo "  2. Run 'startx' for Openbox GUI"
    echo "  3. Right-click for menu"
    echo ""
    echo "Build commands:"
    echo "  ./build.sh       - Build ISO"
    echo "  ./build.sh vm    - Build VM for testing"
    echo "  ./build.sh check - Check flake syntax"
    echo "  ./build.sh clean - Clean artifacts"
    echo ""
}

case "${1:-}" in
    vm)     build_vm ;;
    raw)    build_raw ;;
    clean)  clean ;;
    check)  check_flake ;;
    info)   show_info ;;
    ""|iso) build_iso ;;
    *)
        echo "Usage: $0 [iso|vm|raw|check|clean|info]"
        exit 1
        ;;
esac
