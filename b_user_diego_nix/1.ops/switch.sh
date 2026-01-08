#!/usr/bin/env bash
# Quick switch wrapper for Home Manager
# Usage: ./switch.sh [hostname] [additional args...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="$(dirname "$SCRIPT_DIR")"
HOSTNAME="${1:-$(hostname)}"
CONFIG_NAME="diego@$HOSTNAME"

# Shift off hostname if provided
if [ $# -gt 0 ]; then
    shift
fi

# Try host-specific, fall back to generic
if ! nix flake show "$FLAKE_DIR" 2>/dev/null | grep -q "$CONFIG_NAME"; then
    CONFIG_NAME="diego"
fi

echo "Switching to: $CONFIG_NAME"
home-manager switch --flake "$FLAKE_DIR#$CONFIG_NAME" "$@"

echo ""
echo "Switch complete. Reload your shell or run:"
echo "  exec \$SHELL"
