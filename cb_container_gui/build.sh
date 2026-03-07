#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                    GUI Apps Container — Builder                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   ./build.sh              # Interactive TUI
#   ./build.sh build        # Build image
#   ./build.sh up           # Start container
#   ./build.sh down         # Stop container
#   ./build.sh enter        # Enter shell
#   ./build.sh export       # Export image to tar
#   ./build.sh --help       # Show help

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="gui-apps:latest"
CONTAINER="gui-apps"

# ─── Colors ──────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
    RED='\033[0;31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    GREEN='' YELLOW='' CYAN='' RED='' BOLD='' DIM='' NC=''
fi

log()   { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[-]${NC} %s\n" "$1"; exit 1; }

# ─── Engine Detection ────────────────────────────────────────────────────
detect_engine() {
    if command -v podman >/dev/null 2>&1; then
        ENGINE="podman"
        COMPOSE="podman compose"
    elif command -v docker >/dev/null 2>&1; then
        ENGINE="docker"
        COMPOSE="docker compose"
    else
        error "Neither podman nor docker found"
    fi
}

# ─── Commands ────────────────────────────────────────────────────────────
cmd_build() {
    detect_engine
    log "Building $IMAGE with $ENGINE..."
    cd "$SCRIPT_DIR"
    $ENGINE build -t "$IMAGE" -f Containerfile .
    log "Image built: $IMAGE"
}

cmd_up() {
    detect_engine
    log "Starting $CONTAINER..."
    cd "$SCRIPT_DIR"
    $COMPOSE up -d
    log "Container running: $CONTAINER"
}

cmd_down() {
    detect_engine
    log "Stopping $CONTAINER..."
    cd "$SCRIPT_DIR"
    $COMPOSE down
    log "Container stopped"
}

cmd_enter() {
    detect_engine
    $ENGINE exec -it "$CONTAINER" bash
}

cmd_export() {
    detect_engine
    outfile="${SCRIPT_DIR}/${CONTAINER}.tar"
    log "Exporting $IMAGE to $outfile..."
    $ENGINE save -o "$outfile" "$IMAGE"
    log "Exported: $outfile ($(du -h "$outfile" | cut -f1))"
}

# ─── TUI ─────────────────────────────────────────────────────────────────
run_tui() {
    detect_engine
    printf '\033[2J\033[H'
    printf "\n"
    printf "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║${NC}  ${BOLD}GUI Apps Container${NC}  ${DIM}($ENGINE)${NC}                       ${CYAN}║${NC}\n"
    printf "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
    printf "  ${CYAN}1${NC}) Build image\n"
    printf "  ${CYAN}2${NC}) Start container       ${DIM}(podman compose up)${NC}\n"
    printf "  ${CYAN}3${NC}) Stop container        ${DIM}(podman compose down)${NC}\n"
    printf "  ${CYAN}4${NC}) Enter shell           ${DIM}(bash)${NC}\n"
    printf "  ${CYAN}5${NC}) Export image           ${DIM}(.tar)${NC}\n"
    printf "  ${DIM}q${NC}) Quit\n"
    printf "\n"
    printf "  ${BOLD}Choice:${NC} "
    read -r choice
    case "$choice" in
        1|build)  cmd_build ;;
        2|up)     cmd_up ;;
        3|down)   cmd_down ;;
        4|enter)  cmd_enter ;;
        5|export) cmd_export ;;
        q|quit)   exit 0 ;;
        *)        error "Unknown: $choice" ;;
    esac
}

# ─── Help ────────────────────────────────────────────────────────────────
show_help() {
    cat << 'EOF'
GUI Apps Container — Builder

Usage:
  ./build.sh              Interactive TUI
  ./build.sh build        Build container image
  ./build.sh up           Start container (compose up)
  ./build.sh down         Stop container (compose down)
  ./build.sh enter        Enter container shell (bash)
  ./build.sh export       Export image to .tar
  ./build.sh --help       Show this help
EOF
}

# ─── Main ────────────────────────────────────────────────────────────────
case "${1:-}" in
    -h|--help|help) show_help ;;
    build)          cmd_build ;;
    up)             cmd_up ;;
    down)           cmd_down ;;
    enter)          cmd_enter ;;
    export)         cmd_export ;;
    "")             run_tui ;;
    *)              error "Unknown: $1 (use --help)" ;;
esac
