#!/usr/bin/env bash
# Build container image using Nix
#
# Usage: ./container-build.sh [full|minimal]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

IMAGE_TYPE="${1:-full}"

case "$IMAGE_TYPE" in
  full)
    echo "Building full container image..."
    nix build .#container
    echo ""
    echo "Image built! Load with:"
    echo "  podman load < result"
    echo "  # or"
    echo "  docker load < result"
    ;;
  minimal)
    echo "Building minimal container image..."
    nix build .#container-minimal
    echo ""
    echo "Minimal image built! Load with:"
    echo "  podman load < result"
    ;;
  *)
    echo "Usage: $0 [full|minimal]"
    exit 1
    ;;
esac
