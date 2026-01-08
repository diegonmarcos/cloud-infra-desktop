#!/usr/bin/env bash
# Update flake inputs and rebuild
# Usage: ./update.sh [hostname]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Updating Flake Inputs ==="
nix flake update "$FLAKE_DIR"

echo ""
echo "=== Rebuilding with Updated Inputs ==="
"$SCRIPT_DIR/switch.sh" "$@"

echo ""
echo "Update complete!"
