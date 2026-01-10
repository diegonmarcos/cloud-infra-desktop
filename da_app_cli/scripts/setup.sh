#!/usr/bin/env bash
# ┌───────────────────────────────────────────────────────┐
# │ Diego's CLI Container Setup                           │
# │                                                       │
# │ Fedora + dnf → Docker → Distrobox                    │
# └───────────────────────────────────────────────────────┘

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_CLI_DIR="$(dirname "$SCRIPT_DIR")"
POETRY_DIR="$APP_CLI_DIR/poetry_venv_1"

CONTAINER_NAME="dev"
IMAGE_NAME="diego-cli:latest"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ══════════════════════════════════════════════════════
# Prerequisites check
# ══════════════════════════════════════════════════════
check_prerequisites() {
    log "Checking prerequisites..."

    command -v docker >/dev/null 2>&1 || error "Docker not installed"
    command -v distrobox >/dev/null 2>&1 || error "Distrobox not installed"

    success "All prerequisites met"
}

# ══════════════════════════════════════════════════════
# Build container using Containerfile
# ══════════════════════════════════════════════════════
build_container() {
    log "Building container image..."
    cd "$APP_CLI_DIR"

    docker build -t "$IMAGE_NAME" -f Containerfile .

    success "Container built: $IMAGE_NAME"
}

# ══════════════════════════════════════════════════════
# Create Distrobox
# ══════════════════════════════════════════════════════
create_distrobox() {
    log "Creating Distrobox container..."

    # Remove old container if exists
    distrobox rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true

    # Create new container
    distrobox create \
        --name "$CONTAINER_NAME" \
        --image "$IMAGE_NAME" \
        --yes

    success "Distrobox created: $CONTAINER_NAME"
}

# ══════════════════════════════════════════════════════
# Setup Poetry inside container
# ══════════════════════════════════════════════════════
setup_poetry() {
    log "Setting up Poetry environment inside container..."

    distrobox enter "$CONTAINER_NAME" -- bash -c "
        # Reinstall poetry for container's Python version
        pip3 install --user poetry --force-reinstall 2>/dev/null || true
        poetry config virtualenvs.in-project true
        cd '$POETRY_DIR' 2>/dev/null && poetry install --no-interaction || true
    "

    success "Poetry setup complete"
}

# ══════════════════════════════════════════════════════
# Export common tools to host
# ══════════════════════════════════════════════════════
export_tools() {
    log "Exporting tools to host..."

    local tools=("git" "gh" "rg" "fd" "bat" "jq")

    for tool in "${tools[@]}"; do
        distrobox enter "$CONTAINER_NAME" -- distrobox-export --bin "/usr/bin/$tool" 2>/dev/null || \
        warn "Could not export: $tool"
    done

    success "Tools exported to ~/.local/bin/"
}

# ══════════════════════════════════════════════════════
# Enter container
# ══════════════════════════════════════════════════════
enter_container() {
    distrobox enter "$CONTAINER_NAME"
}

# ══════════════════════════════════════════════════════
# Print usage
# ══════════════════════════════════════════════════════
print_usage() {
    cat << EOF

${GREEN}╔═══════════════════════════════════════════════════════╗
║  Diego's CLI Container - Setup Complete!               ║
╚═══════════════════════════════════════════════════════╝${NC}

${BLUE}Usage:${NC}

  Enter container:
    ${YELLOW}distrobox enter $CONTAINER_NAME${NC}

  Run single command:
    ${YELLOW}distrobox enter $CONTAINER_NAME -- python --version${NC}

  Use Poetry (inside container):
    ${YELLOW}cd $POETRY_DIR && poetry shell${NC}

  Export more tools to host:
    ${YELLOW}distrobox enter $CONTAINER_NAME -- distrobox-export --bin /usr/bin/TOOL${NC}

${BLUE}Rebuild after changes:${NC}
    ${YELLOW}$0 rebuild${NC}

EOF
}

# ══════════════════════════════════════════════════════
# Help
# ══════════════════════════════════════════════════════
show_help() {
    cat << EOF
Diego's CLI Development Container

Usage: ./setup.sh <command>

Commands:
  full       Build image and create distrobox (default)
  build      Build the container image only
  create     Create distrobox container from image
  enter      Enter the container
  rebuild    Remove and rebuild everything
  poetry     Set up Poetry inside container
  export     Export tools to host
  help       Show this help

Quick start:
  ./setup.sh build    # Build image
  ./setup.sh create   # Create distrobox
  ./setup.sh enter    # Enter container

Or just:
  distrobox enter dev
EOF
}

# ══════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════
main() {
    case "${1:-help}" in
        full)
            check_prerequisites
            build_container
            create_distrobox
            print_usage
            ;;
        rebuild)
            build_container
            create_distrobox
            print_usage
            ;;
        build)
            build_container
            ;;
        create)
            create_distrobox
            ;;
        enter)
            enter_container
            ;;
        poetry)
            setup_poetry
            ;;
        export)
            export_tools
            ;;
        help|*)
            show_help
            ;;
    esac
}

main "$@"
