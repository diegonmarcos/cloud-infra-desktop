#!/usr/bin/env bash
# Run container with Podman or Docker
#
# Usage: ./container-run.sh [full|minimal]

set -euo pipefail

IMAGE_TYPE="${1:-full}"

if [[ "$IMAGE_TYPE" == "minimal" ]]; then
  IMAGE="diego-dev-minimal:latest"
else
  IMAGE="diego-dev:latest"
fi

# Detect runtime
if command -v podman &>/dev/null; then
  RUNTIME="podman"
elif command -v docker &>/dev/null; then
  RUNTIME="docker"
else
  echo "Error: Neither podman nor docker found"
  exit 1
fi

echo "Running $IMAGE with $RUNTIME..."

$RUNTIME run -it --rm \
  --name diego-dev-temp \
  --hostname diego-dev \
  --user 1000:1000 \
  -e TERM=xterm-256color \
  -e HOME=/home/diego \
  -v "$HOME/Documents/Git:/home/diego/projects:z" \
  -v "$HOME/.ssh:/home/diego/.ssh:ro,z" \
  -w /home/diego \
  "$IMAGE"
