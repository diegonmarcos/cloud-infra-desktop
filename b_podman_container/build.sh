#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="cloud-connect:minimum"

log() { echo "[$(date +%H:%M:%S)] $1"; }

cmd_build() {
    log "Building container image: $IMAGE_NAME"
    cd "$SCRIPT_DIR"
    podman build -t "$IMAGE_NAME" -f Containerfile .
    log "Build complete!"
    log "Run with: ./build.sh start"
}

cmd_start() {
    log "Starting container..."
    cd "$SCRIPT_DIR"
    podman-compose up -d
    log "Container started!"
    log "Enter with: ./build.sh shell"
}

cmd_stop() {
    log "Stopping container..."
    cd "$SCRIPT_DIR"
    podman-compose down
    log "Container stopped"
}

cmd_shell() {
    log "Entering container shell..."
    podman exec -it cloud-minimum bash
}

cmd_status() {
    podman ps -a --filter "name=cloud-minimum"
}

cmd_clean() {
    log "Removing container and image..."
    podman-compose down 2>/dev/null || true
    podman rmi "$IMAGE_NAME" 2>/dev/null || true
    log "Cleaned"
}

case "${1:-}" in
    build) cmd_build ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    shell) cmd_shell ;;
    status) cmd_status ;;
    clean) cmd_clean ;;
    *) echo "Usage: $0 {build|start|stop|shell|status|clean}" ;;
esac
