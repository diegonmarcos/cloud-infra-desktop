#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Builder Images — Full pipeline: src → dist → GHCR                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Pipeline steps:
#   build    = generate compose + copy src → dist/ (self-contained artifact)
#   docker   = docker build images from dist/ Dockerfiles
#   push     = docker push images from dist/ to GHCR
#   ship     = build + docker + push (full pipeline)
#
# Usage:
#   ./build.sh                          # Interactive TUI
#   ./build.sh build                    # Generate dist/
#   ./build.sh docker [variant]         # Build Docker images
#   ./build.sh push [variant]           # Push images to GHCR
#   ./build.sh ship [variant]           # Full pipeline
#   Variants: x86-cloudlight, arm-cloudlight, x86-forge, all (default)
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
DIST_DIR="$SCRIPT_DIR/dist"
CONFIG="$SCRIPT_DIR/build.json"

REGISTRY=$(jq -r '.registry' "$CONFIG")

# ── Colors ──────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
else
    GREEN='' YELLOW='' RED='' NC=''
fi
log()   { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[-]${NC} %s\n" "$1"; exit 1; }

# ── Engine Detection ────────────────────────────────────────────────────
detect_engine() {
    if command -v docker >/dev/null 2>&1; then
        ENGINE="docker"
    elif command -v podman >/dev/null 2>&1; then
        ENGINE="podman"
    else
        error "Neither docker nor podman found"
    fi
}

# ── GHCR Login ──────────────────────────────────────────────────────────
ghcr_login() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "$GITHUB_TOKEN" | $ENGINE login ghcr.io -u "${GITHUB_ACTOR:-diegonmarcos}" --password-stdin
    elif command -v gh >/dev/null 2>&1; then
        gh auth token | $ENGINE login ghcr.io -u "$(gh api user --jq .login)" --password-stdin
    else
        error "No GHCR credentials (set GITHUB_TOKEN or install gh CLI)"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# STEP 1: BUILD — src/ + flake → dist/ (self-contained artifact)
# ═══════════════════════════════════════════════════════════════════
step_build() {
    log "Step 1: BUILD — generating dist/..."
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"

    # Copy all src/ files (Dockerfiles, flake, entrypoint, deps, etc.)
    cp -rL "$SRC_DIR"/* "$DIST_DIR/"

    # Generate compose files from flake → overwrite into dist/
    cd "$SRC_DIR"
    nix build --no-link --print-out-paths 2>/dev/null | while read -r path; do
        cp -rL "$path"/*.yaml "$DIST_DIR/" 2>/dev/null || true
        cp -rL "$path"/*.json "$DIST_DIR/" 2>/dev/null || true
    done

    log "dist/ contents:"
    ls -1 "$DIST_DIR/" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════
# STEP 2: DOCKER — build images from dist/ Dockerfiles
# ═══════════════════════════════════════════════════════════════════
step_docker() {
    _variant="${1:-all}"
    detect_engine

    [ ! -d "$DIST_DIR" ] && { error "No dist/ — run build first"; }

    if [ "$_variant" = "all" ]; then
        for v in $(jq -r '.images | keys[]' "$CONFIG"); do
            _docker_build "$v"
        done
    else
        _docker_build "$_variant"
    fi
}

_docker_build() {
    _variant="$1"
    _ghcr=$(jq -r ".images.\"$_variant\".ghcr" "$CONFIG")
    _dockerfile=$(jq -r ".images.\"$_variant\".dockerfile" "$CONFIG")
    _platform=$(jq -r ".images.\"$_variant\".platform // empty" "$CONFIG")

    [ "$_ghcr" = "null" ] && { error "Unknown variant: $_variant"; }

    # Dockerfile is in dist/ (copied from src/ by step_build)
    _dockerfile_name=$(basename "$_dockerfile")
    _dockerfile_path="$DIST_DIR/$_dockerfile_name"
    [ ! -f "$_dockerfile_path" ] && { warn "$_variant: $_dockerfile_path not found — skipping"; return 0; }

    log "Step 2: DOCKER BUILD — $_variant: $_ghcr"
    log "  Dockerfile: $_dockerfile_path"
    log "  Context: $DIST_DIR"

    _args=""
    [ -n "$_platform" ] && _args="--platform=$_platform"

    $ENGINE build $_args -t "$_ghcr:latest" -f "$_dockerfile_path" "$DIST_DIR"
    log "Built: $_ghcr:latest"
}

# ═══════════════════════════════════════════════════════════════════
# STEP 3: PUSH — push images from dist/ to GHCR
# ═══════════════════════════════════════════════════════════════════
step_push() {
    _variant="${1:-all}"
    detect_engine
    ghcr_login

    if [ "$_variant" = "all" ]; then
        for v in $(jq -r '.images | keys[]' "$CONFIG"); do
            _docker_push "$v"
        done
    else
        _docker_push "$_variant"
    fi
}

_docker_push() {
    _variant="$1"
    _ghcr=$(jq -r ".images.\"$_variant\".ghcr" "$CONFIG")
    [ "$_ghcr" = "null" ] && { error "Unknown variant: $_variant"; }

    log "Step 3: PUSH — $_ghcr:latest"
    $ENGINE push "$_ghcr:latest"
    log "Pushed: $_ghcr:latest"
}

# ═══════════════════════════════════════════════════════════════════
# SHIP — full pipeline: build + docker + push
# ═══════════════════════════════════════════════════════════════════
step_ship() {
    _variant="${1:-all}"
    step_build
    step_docker "$_variant"
    step_push "$_variant"
}

# ═══════════════════════════════════════════════════════════════════
# TUI Menu
# ═══════════════════════════════════════════════════════════════════
show_menu() {
    printf "\n"
    printf "  Builder Images\n"
    printf "  ──────────────────────────────────\n"
    _n=1
    for v in $(jq -r '.images | keys[]' "$CONFIG"); do
        _desc=$(jq -r ".images.\"$v\".description" "$CONFIG")
        printf "  %d) %-20s %s\n" "$_n" "$v" "$_desc"
        _n=$(( _n + 1 ))
    done
    printf "  ──────────────────────────────────\n"
    printf "  a) build       Generate dist/\n"
    printf "  b) docker all  Build all images\n"
    printf "  c) ship all    Full pipeline\n"
    printf "> "
    read -r _choice
    case "$_choice" in
        a) step_build ;;
        b) step_docker all ;;
        c) step_ship all ;;
        [0-9]*)
            _v=$(jq -r ".images | keys[$(( _choice - 1 ))]" "$CONFIG")
            [ "$_v" = "null" ] && { echo "Invalid"; show_menu; return; }
            printf "  1) build  2) docker  3) push  4) ship\n> "
            read -r _action
            case "$_action" in
                1) step_build ;; 2) step_docker "$_v" ;;
                3) step_push "$_v" ;; 4) step_ship "$_v" ;;
                *) echo "Invalid" ;;
            esac ;;
        *) echo "Invalid"; show_menu ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════
# Entry Point
# ═══════════════════════════════════════════════════════════════════
case "${1:-}" in
    "")          show_menu ;;
    build)       step_build ;;
    docker)      step_docker "${2:-all}" ;;
    push)        step_push "${2:-all}" ;;
    ship)        step_ship "${2:-all}" ;;
    --help|-h)
        echo "Usage: $0 [build|docker|push|ship [variant]]"
        echo "Variants: $(jq -r '.images | keys | join(", ")' "$CONFIG"), all (default)"
        echo ""
        echo "Steps:"
        echo "  build   src/ + flake → dist/ (compose + Dockerfiles + deps)"
        echo "  docker  build images from dist/ Dockerfiles"
        echo "  push    push images to GHCR"
        echo "  ship    build + docker + push (full pipeline)"
        ;;
    *)           error "Unknown command: $1 (use: build, docker, push, ship)" ;;
esac
