#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# Remote Deployment Script - Deploy configs to new Kinoite installation
# ═══════════════════════════════════════════════════════════════════════════
#
# Usage: ./deploy-remote.sh <target-ip> [user]
#
# Prerequisites on target:
#   1. SSH server running (systemctl start sshd)
#   2. User exists with sudo access
#
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Args
TARGET_IP="${1:-}"
TARGET_USER="${2:-diego}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -z "$TARGET_IP" ]; then
    echo "Usage: $0 <target-ip> [user]"
    echo "Example: $0 192.168.1.100 diego"
    exit 1
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════════════════════╗"
echo "║              Remote Deployment to Fedora Kinoite                          ║"
echo "╚═══════════════════════════════════════════════════════════════════════════╝"
echo ""
log_info "Target: ${TARGET_USER}@${TARGET_IP}"
log_info "Source: ${PARENT_DIR}"
echo ""

# Test SSH connection
log_info "Testing SSH connection..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${TARGET_USER}@${TARGET_IP}" "echo 'SSH OK'" 2>/dev/null; then
    log_error "Cannot connect. Make sure:"
    echo "  1. Target is booted into Kinoite"
    echo "  2. SSH is enabled: sudo systemctl start sshd"
    echo "  3. User '${TARGET_USER}' exists"
    echo "  4. SSH key is authorized or use: ssh-copy-id ${TARGET_USER}@${TARGET_IP}"
    exit 1
fi
log_success "SSH connection OK"

# Create remote directory
log_info "Creating remote directory..."
ssh "${TARGET_USER}@${TARGET_IP}" "mkdir -p ~/desktop_image"

# Copy files
log_info "Copying spec/ folder..."
scp -r "${SCRIPT_DIR}" "${TARGET_USER}@${TARGET_IP}:~/desktop_image/"

log_info "Copying dotfiles_src/ folder..."
scp -r "${PARENT_DIR}/dotfiles_src" "${TARGET_USER}@${TARGET_IP}:~/desktop_image/"

log_success "Files copied to ~/desktop_image/"

# Make inject.sh executable
ssh "${TARGET_USER}@${TARGET_IP}" "chmod +x ~/desktop_image/spec/inject.sh"

echo ""
echo "╔═══════════════════════════════════════════════════════════════════════════╗"
echo "║                         Deployment Complete!                              ║"
echo "╚═══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps on target (${TARGET_IP}):"
echo ""
echo "  1. SSH into target:"
echo "     ssh ${TARGET_USER}@${TARGET_IP}"
echo ""
echo "  2. Run dry-run first:"
echo "     cd ~/desktop_image/spec"
echo "     sudo ./inject.sh --dry-run"
echo ""
echo "  3. Apply all configurations:"
echo "     sudo ./inject.sh --all"
echo ""
echo "  4. Or apply selectively:"
echo "     sudo ./inject.sh --users --ssh --dotfiles"
echo "     sudo ./inject.sh --surface"
echo ""
