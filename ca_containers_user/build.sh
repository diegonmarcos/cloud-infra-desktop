#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ User Container Images — Full pipeline: src → dist → GHCR                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Pipeline steps:
#   build    = generate compose + copy src → dist/ (self-contained artifact)
#   docker   = docker build images from dist/ Containerfiles
#   push     = docker push images from dist/ to GHCR
#   ship     = build + docker + push (full pipeline)
#
# Usage:
#   ./build.sh                          # Interactive TUI
#   ./build.sh build                    # Generate dist/
#   ./build.sh docker [variant]         # Build Docker images
#   ./build.sh push [variant]           # Push images to GHCR
#   ./build.sh ship [variant]           # Full pipeline
#   Variants: deb-nix, deb-apt, nixos-hm, all (default)
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
# Refuse to build an image that bakes a private repo into a public layer.
# Data-driven from build.json::private_repos - see the _doc there for why a
# token is not the fix. Runs before anything is generated, so a bad
# Containerfile never reaches dist/, let alone GHCR.
assert_no_private_repos() {
    local repo hits found=0
    while read -r repo; do
        [ -z "$repo" ] && continue
        hits="$(command grep -rn "diegonmarcos/${repo}\(\.git\)\?" "$SRC_DIR" 2>/dev/null \
                | command grep -v '^[^:]*:[0-9]*:#' || true)"
        if [ -n "$hits" ]; then
            found=1
            echo "FATAL: private repo '${repo}' is cloned at image build time:" >&2
            printf '%s\n' "$hits" >&2
        fi
    done < <(python3 -c "import json;print('\n'.join(json.load(open('$SCRIPT_DIR/build.json')).get('private_repos',[])))")
    if [ "$found" = "1" ]; then
        echo "These images publish to a PUBLIC registry. Clone private content at RUNTIME with an injected key." >&2
        exit 1
    fi
    log "guard: no private repo cloned at build time"
}

step_build() {
    log "Step 1: BUILD — generating dist/..."
    assert_no_private_repos
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"

    # Copy all src/ files (Containerfiles, distrobox, flake, etc.)
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
# STEP 2: DOCKER — build images from dist/ Containerfiles
# ═══════════════════════════════════════════════════════════════════
step_docker() {
    _variant="${1:-all}"
    detect_engine

    [ ! -d "$DIST_DIR" ] && { error "No dist/ — run build first"; }

    case "$_variant" in
        deb-nix)   _docker_build_containerfile deb-nix "user-dev-x86-deb-nix-hm" ;;
        deb-apt)   _docker_build_containerfile deb-apt "user-dev-x86-deb-apt" ;;
        nixos-hm)  _docker_build_nix ;;
        all)
            _docker_build_containerfile deb-nix "user-dev-x86-deb-nix-hm"
            _docker_build_containerfile deb-apt "user-dev-x86-deb-apt"
            _docker_build_nix ;;
        *)         error "Unknown variant: $_variant" ;;
    esac
}

_docker_build_containerfile() {
    _variant="$1"; _name="$2"
    _img="$REGISTRY/$_name:latest"
    _containerfile="$DIST_DIR/Containerfile.$_variant"

    [ ! -f "$_containerfile" ] && { warn "$_variant: $_containerfile not found — skipping"; return 0; }

    log "Step 2: DOCKER BUILD — $_variant: $_img"
    log "  Containerfile: $_containerfile"
    log "  Context: $DIST_DIR"

    $ENGINE build --network=host -t "$_img" -f "$_containerfile" "$DIST_DIR"
    log "Built: $_img"
}

_docker_build_nix() {
    _img="$REGISTRY/user-dev-x86-nixos-nix-hm:latest"
    _hm_flake=$(jq -r '.images["nixos-hm"].hm_flake' "$CONFIG")
    _flake_path="$SCRIPT_DIR/$_hm_flake"

    log "Step 2: DOCKER BUILD — nixos-hm: $_img (dockerTools)"
    log "  Flake: $_flake_path"

    _tarball=$(nix build "$_flake_path#container-nixos-hm" --impure --no-link --print-out-paths 2>/dev/null || true)
    if [ -n "$_tarball" ] && [ -f "$_tarball" ]; then
        $ENGINE load < "$_tarball"
        log "Built: $_img (from nix)"
    else
        warn "nixos-hm: flake output #container-nixos-hm not found — skipping"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# STEP 3: PUSH — push images to GHCR
# ═══════════════════════════════════════════════════════════════════
step_push() {
    _variant="${1:-all}"
    detect_engine
    ghcr_login

    case "$_variant" in
        deb-nix)   _docker_push "user-dev-x86-deb-nix-hm" ;;
        deb-apt)   _docker_push "user-dev-x86-deb-apt" ;;
        nixos-hm)  _docker_push "user-dev-x86-nixos-nix-hm" ;;
        all)
            _docker_push "user-dev-x86-deb-nix-hm"
            _docker_push "user-dev-x86-deb-apt"
            _docker_push "user-dev-x86-nixos-nix-hm" ;;
        *)         error "Unknown variant: $_variant" ;;
    esac
}

_docker_push() {
    _img="$REGISTRY/$1:latest"
    log "Step 3: PUSH — $_img"
    $ENGINE push "$_img"
    log "Pushed: $_img"
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
    printf "  User Container Images\n"
    printf "  ──────────────────────────────────\n"
    printf "  1) deb-nix     Debian + Nix + HM\n"
    printf "  2) deb-apt     Debian + apt\n"
    printf "  3) nixos-hm    Pure Nix (dockerTools)\n"
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
        1) step_ship deb-nix ;; 2) step_ship deb-apt ;; 3) step_ship nixos-hm ;;
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
        echo "Variants: deb-nix, deb-apt, nixos-hm, all (default)"
        echo ""
        echo "Steps:"
        echo "  build   src/ + flake → dist/ (compose + Containerfiles + deps)"
        echo "  docker  build images from dist/ Containerfiles"
        echo "  push    push images to GHCR"
        echo "  ship    build + docker + push (full pipeline)"
        ;;
    *)           error "Unknown command: $1 (use: build, docker, push, ship)" ;;
esac
