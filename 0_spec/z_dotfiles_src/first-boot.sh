#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# First Boot Script - Run this on fresh Kinoite installation
# ═══════════════════════════════════════════════════════════════════════════
#
# Run this on the Kinoite console to prepare for remote deployment:
#   curl -sL <url> | bash
#   OR copy this script and run it
#
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

echo "╔═══════════════════════════════════════════════════════════════════════════╗"
echo "║              Fedora Kinoite - First Boot Setup                            ║"
echo "╚═══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Get current user
CURRENT_USER="${SUDO_USER:-$USER}"
echo "[INFO] Current user: $CURRENT_USER"

# Enable and start SSH
echo "[INFO] Enabling SSH server..."
sudo systemctl enable sshd
sudo systemctl start sshd
echo "[OK] SSH server running"

# Show IP address
echo ""
echo "[INFO] Network addresses:"
ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1'
echo ""

# Install jq (needed for inject.sh)
echo "[INFO] Installing jq..."
sudo rpm-ostree install jq --idempotent || echo "[WARN] jq install queued for next boot"

# Firewall - allow SSH
echo "[INFO] Configuring firewall..."
sudo firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
sudo firewall-cmd --reload 2>/dev/null || true
echo "[OK] Firewall configured"

echo ""
echo "╔═══════════════════════════════════════════════════════════════════════════╗"
echo "║                         First Boot Complete!                              ║"
echo "╚═══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "SSH is now accessible. From the Ubuntu host, run:"
echo ""
echo "  ./deploy-remote.sh <this-ip> $CURRENT_USER"
echo ""
echo "Note: If jq was installed, reboot first: sudo systemctl reboot"
echo ""
