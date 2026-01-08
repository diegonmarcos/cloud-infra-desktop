#!/usr/bin/env bash
# Create distrobox from Nix-built image
#
# Usage: ./distrobox-create.sh [name]

set -euo pipefail

BOX_NAME="${1:-diego-dev}"
IMAGE="diego-dev:latest"

# Check if distrobox is installed
if ! command -v distrobox &>/dev/null; then
  echo "Error: distrobox not found"
  echo "Install with: curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local"
  exit 1
fi

# Check if image exists
if ! podman image exists "$IMAGE" 2>/dev/null && ! docker image inspect "$IMAGE" &>/dev/null; then
  echo "Image $IMAGE not found. Building..."
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$SCRIPT_DIR/container-build.sh" full
  podman load < "$(dirname "$SCRIPT_DIR")/result"
fi

# Create distrobox
echo "Creating distrobox: $BOX_NAME"
distrobox create \
  --name "$BOX_NAME" \
  --image "$IMAGE" \
  --home "$HOME" \
  --yes

echo ""
echo "Distrobox created! Enter with:"
echo "  distrobox enter $BOX_NAME"
