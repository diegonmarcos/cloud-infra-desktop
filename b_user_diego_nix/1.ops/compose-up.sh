#!/usr/bin/env bash
# Start container with compose
#
# Usage: ./compose-up.sh [podman|docker]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR/container"

RUNTIME="${1:-}"

# Auto-detect runtime
if [[ -z "$RUNTIME" ]]; then
  if command -v podman-compose &>/dev/null; then
    RUNTIME="podman"
  elif command -v docker &>/dev/null; then
    RUNTIME="docker"
  else
    echo "Error: Neither podman-compose nor docker found"
    exit 1
  fi
fi

case "$RUNTIME" in
  podman)
    echo "Starting with podman-compose..."
    podman-compose up -d
    echo ""
    echo "Container started! Enter with:"
    echo "  podman-compose exec dev fish"
    ;;
  docker)
    echo "Starting with docker compose..."
    docker compose up -d
    echo ""
    echo "Container started! Enter with:"
    echo "  docker compose exec dev fish"
    ;;
  *)
    echo "Usage: $0 [podman|docker]"
    exit 1
    ;;
esac
