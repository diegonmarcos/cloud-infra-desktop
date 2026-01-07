#!/usr/bin/env bash
# Home Manager Bootstrap Script for Non-NixOS Systems
# Usage: ./install.sh [hostname]

set -euo pipefail

HOSTNAME="${1:-$(hostname)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Home Manager Bootstrap ==="
echo "Hostname: $HOSTNAME"
echo "Flake directory: $FLAKE_DIR"
echo ""

# Check if Nix is installed
if ! command -v nix &>/dev/null; then
    echo "Installing Nix..."
    echo "This will install Nix in multi-user mode (with daemon)"
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled"
        exit 1
    fi

    curl -L https://nixos.org/nix/install | sh -s -- --daemon

    # Source Nix
    if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
        . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
    fi
fi

# Enable flakes and nix-command if not already
mkdir -p ~/.config/nix
if ! grep -q "experimental-features" ~/.config/nix/nix.conf 2>/dev/null; then
    echo "Enabling Nix flakes..."
    echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
fi

# Determine configuration name
CONFIG_NAME="diego@$HOSTNAME"
if ! nix flake show "$FLAKE_DIR" 2>/dev/null | grep -q "$CONFIG_NAME"; then
    echo "No specific config for '$HOSTNAME', using default 'diego'"
    CONFIG_NAME="diego"
fi

# Apply configuration
echo ""
echo "Applying Home Manager configuration: $CONFIG_NAME"
nix run home-manager/release-24.11 -- switch --flake "$FLAKE_DIR#$CONFIG_NAME"

echo ""
echo "=== Installation Complete ==="
echo "Configuration applied: $CONFIG_NAME"
echo ""
echo "IMPORTANT: Reload your shell or run:"
echo "  source ~/.bashrc    # for bash"
echo "  source ~/.zshrc     # for zsh"
echo "  exec fish           # for fish"
echo ""
echo "To update in the future:"
echo "  home-manager switch --flake $FLAKE_DIR#$CONFIG_NAME"
echo "Or use the helper scripts:"
echo "  $SCRIPT_DIR/switch.sh"
echo "  $SCRIPT_DIR/update.sh"
