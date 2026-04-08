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
#   Variants: cloudlight, apt, forge, all (default) — all multi-arch (amd64 + arm64)
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
        for v in $(jq -r '.images | keys_unsorted[]' "$CONFIG"); do
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

    # Multi-arch: use buildx for multi-platform, regular build for single
    if echo "$_platform" | grep -q ","; then
        log "  Multi-arch: $_platform (buildx, push-only — use 'push' or 'ship' to push)"
        log "  Skipping local build (multi-arch requires --push, done in push step)"
    elif [ -n "$_platform" ]; then
        $ENGINE build --network=host --platform="$_platform" -t "$_ghcr:latest" -f "$_dockerfile_path" "$DIST_DIR"
    else
        $ENGINE build --network=host -t "$_ghcr:latest" -f "$_dockerfile_path" "$DIST_DIR"
    fi
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
        for v in $(jq -r '.images | keys_unsorted[]' "$CONFIG"); do
            _docker_push "$v"
        done
    else
        _docker_push "$_variant"
    fi
}

_docker_push() {
    _variant="$1"
    _ghcr=$(jq -r ".images.\"$_variant\".ghcr" "$CONFIG")
    _platform=$(jq -r ".images.\"$_variant\".platform // empty" "$CONFIG")
    _dockerfile=$(jq -r ".images.\"$_variant\".dockerfile" "$CONFIG")
    [ "$_ghcr" = "null" ] && { error "Unknown variant: $_variant"; }

    # Multi-arch: rebuild with --push (buildx can't push after --load for multi-platform)
    if echo "$_platform" | grep -q ","; then
        _dockerfile_path="$DIST_DIR/$(basename "$_dockerfile")"
        log "Step 3: PUSH (multi-arch buildx) — $_ghcr:latest"
        $ENGINE buildx build --network=host --platform="$_platform" -t "$_ghcr:latest" -f "$_dockerfile_path" "$DIST_DIR" --push
    else
        log "Step 3: PUSH — $_ghcr:latest"
        $ENGINE push "$_ghcr:latest"
    fi
    log "Pushed: $_ghcr:latest"
    $ENGINE image prune -f >/dev/null 2>&1 || true
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
    for v in $(jq -r '.images | keys_unsorted[]' "$CONFIG"); do
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
            _v=$(jq -r ".images | keys_unsorted[$(( _choice - 1 ))]" "$CONFIG")
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
# Run — start container interactively
# ═══════════════════════════════════════════════════════════════════
step_run() {
    _variant="${1:-x-deb-nixhm}"
    _variant=$(resolve_variant "$_variant")
    [ -z "$_variant" ] && return 1
    _ghcr=$(jq -r ".images.\"$_variant\".ghcr" "$CONFIG")
    log "Running $_ghcr:latest interactively"
    # Use compose if available, else docker run
    if [ -f "$DIST_DIR/docker/compose.yaml" ]; then
        docker compose -f "$DIST_DIR/docker/compose.yaml" run --rm cloud-builder bash
    else
        docker run -it --rm --network=host \
            -v /var/run/docker.sock:/var/run/docker.sock \
            "$_ghcr:latest" bash
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Resolve variant — by name or number
# ═══════════════════════════════════════════════════════════════════
resolve_variant() {
    _input="$1"
    if echo "$_input" | grep -q '^[0-9]'; then
        _idx=$(( _input - 1 ))
        _resolved=$(jq -r ".images | keys_unsorted[$_idx]" "$CONFIG")
        [ "$_resolved" = "null" ] && { error "Invalid variant number: $_input"; return 1; }
        echo "$_resolved"
    else
        echo "$_input"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Entry Point
# ═══════════════════════════════════════════════════════════════════
_show_help() {
    echo "Builder Images"
    echo ""
    echo "  Commands:"
    echo "    a)  ship              full pipeline: flake-build + image-build + image-push"
    echo "    a0) flake-build       src/ + flake → dist/"
    echo "    a1) image-build       build docker image locally"
    echo "    a2) image-push        build + push to GHCR (multi-arch)"
    echo "    b)  run               pull + start container interactively"
    echo "    b0) image-pull        pull latest image from GHCR"
    echo "    b1) image-run         start container (no pull)"
    echo "    c)  list              list running containers + local images + stats"
    echo "    c0) list-containers   list running containers"
    echo "    c1) list-images       list local images"
    echo "    c2) container-stats   live resource usage"
    echo ""
    echo "  Images:"
    _n=1
    for v in $(jq -r '.images | keys_unsorted[]' "$CONFIG"); do
        _desc=$(jq -r ".images.\"$v\".description" "$CONFIG")
        printf "    %d) %-25s %s\n" "$_n" "$v" "$_desc"
        _n=$(( _n + 1 ))
    done
    echo ""
    echo "  Usage: $0 <command> <image-name|number>"
    echo ""
    echo "  Examples:"
    echo "    $0 ship 1                          # ship cloud-builder-x-deb-nixhm"
    echo "    $0 ship cloud-builder-x-deb-nixhm  # same, by name"
    echo "    $0 ship all                        # ship all images"
    echo "    $0 run 1                           # pull + shell in cloud-builder-x-deb-nixhm"
    echo "    $0 b1 1                            # shell without pull"
    echo "    $0 a 1                             # ship image 1"
    echo "    $0 b 1                             # run image 1"
}

case "${1:-}" in
    ""|--help|-h)    _show_help ;;
    menu)            show_menu ;;
    # a) ship pipeline
    ship|a)          step_ship "$(resolve_variant "${2:-all}")" ;;
    a0|flake-build)  step_build ;;
    a1|image-build)  step_docker "$(resolve_variant "${2:-all}")" ;;
    a2|image-push)   step_push "$(resolve_variant "${2:-all}")" ;;
    # b) run (pull + run)
    run|b)           _v=$(resolve_variant "${2:-1}"); _ghcr=$(jq -r ".images.\"$_v\".ghcr" "$CONFIG"); docker pull "$_ghcr:latest" 2>&1 | tail -3; step_run "$_v" ;;
    b0|image-pull)   _v=$(resolve_variant "${2:-1}"); _ghcr=$(jq -r ".images.\"$_v\".ghcr" "$CONFIG"); docker pull "$_ghcr:latest" ;;
    b1|image-run)    step_run "$(resolve_variant "${2:-1}")" ;;
    # c) list
    list|c)          docker ps -a --filter "name=cloud-builder" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null; echo ""; docker images --filter "reference=ghcr.io/diegonmarcos/cloud-builder-*" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" 2>/dev/null; echo ""; docker stats --no-stream --filter "name=cloud-builder" --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" 2>/dev/null ;;
    c0|list-containers) docker ps -a --filter "name=cloud-builder" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null ;;
    c1|list-images)  docker images --filter "reference=ghcr.io/diegonmarcos/cloud-builder-*" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" 2>/dev/null ;;
    c2|container-stats) docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Size}}\t{{.Status}}" 2>/dev/null; echo ""; docker stats --no-stream 2>/dev/null ;;
    # Legacy aliases
    build)           step_build ;;
    docker)          step_docker "$(resolve_variant "${2:-all}")" ;;
    push)            step_push "$(resolve_variant "${2:-all}")" ;;
    *)               error "Unknown: $1 — run '$0' for help" ;;
esac
