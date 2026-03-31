#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Builder Images — Build + Push CI/CD builder images to GHCR              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   ./build.sh                          # Interactive TUI
#   ./build.sh build [variant]          # Build image(s) locally
#   ./build.sh ship [variant]           # Build + push to GHCR
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

# ── Step: Build (src/ + flake → dist/) ─────────────────────────────────
step_build() {
    log "Building dist/ (self-contained production artifact)..."
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"

    # 1. Copy all src/ files (Dockerfiles, flake, entrypoint, etc.)
    cp -rL "$SRC_DIR"/* "$DIST_DIR/"

    # 2. Generate compose files from flake
    cd "$SRC_DIR"
    nix build --no-link --print-out-paths 2>/dev/null | while read -r path; do
        cp -rL "$path"/*.yaml "$DIST_DIR/" 2>/dev/null || true
        cp -rL "$path"/*.json "$DIST_DIR/" 2>/dev/null || true
    done

    log "dist/ contents:"
    ls -la "$DIST_DIR/" 2>/dev/null
}

# ── Build a single variant ──────────────────────────────────────────────
_build_variant() {
    _variant="$1"
    _push="${2:-false}"

    _ghcr=$(jq -r ".images.\"$_variant\".ghcr" "$CONFIG")
    _dockerfile=$(jq -r ".images.\"$_variant\".dockerfile" "$CONFIG")
    _build_args=$(jq -r ".images.\"$_variant\".build_args // empty" "$CONFIG")
    _platform=$(jq -r ".images.\"$_variant\".platform // empty" "$CONFIG")

    [ "$_ghcr" = "null" ] && { error "Unknown variant: $_variant"; }

    _dockerfile_path="$SCRIPT_DIR/$_dockerfile"
    [ ! -f "$_dockerfile_path" ] && { warn "$_variant: Dockerfile not found at $_dockerfile_path — skipping"; return 0; }

    log "Building $_variant: $_ghcr"
    log "  Dockerfile: $_dockerfile_path"

    _args=""
    [ -n "$_build_args" ] && _args="--build-arg $_build_args"
    [ -n "$_platform" ] && _args="$_args --platform=$_platform"

    $ENGINE build $_args -t "$_ghcr:latest" -f "$_dockerfile_path" "$SRC_DIR"

    if [ "$_push" = "true" ]; then
        log "Pushing $_ghcr:latest"
        $ENGINE push "$_ghcr:latest"
        log "Pushed: $_ghcr:latest"
    fi
}

# ── Step: Docker build ──────────────────────────────────────────────────
step_docker() {
    _variant="${1:-all}"
    detect_engine

    if [ "$_variant" = "all" ]; then
        for v in $(jq -r '.images | keys[]' "$CONFIG"); do
            _build_variant "$v" false
        done
    else
        _build_variant "$_variant" false
    fi
}

# ── Step: Ship (compose + docker build + push) ────────────────────────
step_ship() {
    _variant="${1:-all}"
    step_build
    detect_engine
    ghcr_login

    if [ "$_variant" = "all" ]; then
        for v in $(jq -r '.images | keys[]' "$CONFIG"); do
            _build_variant "$v" true
        done
    else
        _build_variant "$_variant" true
    fi
}

# ── TUI Menu ───────────────────────────────────────────────────────────
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
    printf "  a) build all    b) ship all\n"
    printf "> "
    read -r _choice
    case "$_choice" in
        a) step_build all ;;
        b) step_ship all ;;
        [0-9]*)
            _v=$(jq -r ".images | keys[$((  _choice - 1 ))]" "$CONFIG")
            [ "$_v" = "null" ] && { echo "Invalid"; show_menu; return; }
            printf "  1) build    2) ship\n> "
            read -r _action
            case "$_action" in
                1) step_build "$_v" ;; 2) step_ship "$_v" ;;
                *) echo "Invalid" ;;
            esac ;;
        *) echo "Invalid"; show_menu ;;
    esac
}

# ── Entry Point ─────────────────────────────────────────────────────────
case "${1:-}" in
    "")          show_menu ;;
    build)       step_build ;;
    docker)      step_docker "${2:-all}" ;;
    ship)        step_ship "${2:-all}" ;;
    --help|-h)
        echo "Usage: $0 [build|ship [variant]]"
        echo "Variants: $(jq -r '.images | keys | join(", ")' "$CONFIG"), all (default)"
        ;;
    *)           error "Unknown command: $1 (use: build, ship)" ;;
esac
