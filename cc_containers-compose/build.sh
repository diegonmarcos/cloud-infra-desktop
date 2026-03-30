#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Containers Compose — Build + Push all 3 image variants                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   ./build.sh              # Interactive TUI
#   ./build.sh build        # Generate compose files from flake → dist/
#   ./build.sh push         # Build + push all Docker images to GHCR
#   ./build.sh push deb-nix # Build + push single variant
#   ./build.sh ship         # build + push (full pipeline)
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

# ── Step: Build (nix flake → dist/) ────────────────────────────────────
step_build() {
    log "Building compose files from flake..."
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"

    cd "$SRC_DIR"
    nix build --no-link --print-out-paths 2>/dev/null | while read -r path; do
        cp -rL "$path"/* "$DIST_DIR/"
    done

    log "Generated in dist/:"
    ls -la "$DIST_DIR"/*.yaml 2>/dev/null || warn "No compose files generated"
}

# ── Step: Push Docker images to GHCR ───────────────────────────────────
step_push() {
    _variant="${1:-all}"
    detect_engine
    ghcr_login

    case "$_variant" in
        deb-nix)
            _push_deb_nix ;;
        deb-apt)
            _push_deb_apt ;;
        nixos-hm)
            _push_nixos_hm ;;
        all)
            _push_deb_nix
            _push_deb_apt
            _push_nixos_hm ;;
        *)
            error "Unknown variant: $_variant (use: deb-nix, deb-apt, nixos-hm, all)" ;;
    esac
}

_push_deb_nix() {
    _img="$REGISTRY/diego-deb-nix:latest"
    _containerfile="$SRC_DIR/Containerfile.deb-nix"

    if [ ! -f "$_containerfile" ]; then
        error "deb-nix Containerfile not found at $_containerfile"
    fi

    log "Building deb-nix: $_img"
    log "  Containerfile: $_containerfile"

    $ENGINE build -t "$_img" -f "$_containerfile" "$SRC_DIR"
    $ENGINE push "$_img"
    log "Pushed: $_img"
}

_push_deb_apt() {
    _img="$REGISTRY/diego-deb-apt:latest"
    _containerfile="$SRC_DIR/Containerfile.deb-apt"

    if [ ! -f "$_containerfile" ]; then
        warn "deb-apt Containerfile not found at $_containerfile — skipping"
        return 0
    fi

    log "Building deb-apt: $_img"
    $ENGINE build -t "$_img" -f "$_containerfile" "$SRC_DIR"
    $ENGINE push "$_img"
    log "Pushed: $_img"
}

_push_nixos_hm() {
    _img="$REGISTRY/diego-nixos-hm:latest"
    _hm_flake=$(jq -r '.images["nixos-hm"].hm_flake' "$CONFIG")
    _hm_config=$(jq -r '.images["nixos-hm"].hm_config' "$CONFIG")

    log "Building nixos-hm: $_img"
    log "  HM flake: $SCRIPT_DIR/$_hm_flake"
    log "  HM config: $_hm_config"

    # Build via dockerTools in the HM flake (requires container-nixos-hm output)
    _flake_path="$SCRIPT_DIR/$_hm_flake"
    if nix build "$_flake_path#container-nixos-hm" --no-link --print-out-paths 2>/dev/null | read -r _tarball; then
        $ENGINE load < "$_tarball"
        $ENGINE push "$_img"
        log "Pushed: $_img"
    else
        warn "nixos-hm: flake output #container-nixos-hm not found — skipping"
        warn "  Add dockerTools.buildLayeredImage output to $_flake_path/flake.nix"
    fi
}

# ── Step: Ship (build + push) ──────────────────────────────────────────
step_ship() {
    step_build
    step_push "${1:-all}"
}

# ── TUI Menu ───────────────────────────────────────────────────────────
show_menu() {
    printf "\n"
    printf "  Containers Compose\n"
    printf "  ──────────────────────────────────\n"
    printf "  1) build         Generate compose files (flake → dist/)\n"
    printf "  2) push all      Build + push all 3 images to GHCR\n"
    printf "  3) push deb-nix  Build + push deb-nix only\n"
    printf "  4) push deb-apt  Build + push deb-apt only\n"
    printf "  5) push nixos-hm Build + push nixos-hm only\n"
    printf "  6) ship          Full pipeline (build + push all)\n"
    printf "  ──────────────────────────────────\n"
    printf "> "
    read -r _choice
    case "$_choice" in
        1) step_build ;;
        2) step_push all ;;
        3) step_push deb-nix ;;
        4) step_push deb-apt ;;
        5) step_push nixos-hm ;;
        6) step_ship ;;
        *) echo "Invalid"; show_menu ;;
    esac
}

# ── Entry Point ─────────────────────────────────────────────────────────
case "${1:-}" in
    "")          show_menu ;;
    build)       step_build ;;
    push)        step_push "${2:-all}" ;;
    ship)        step_ship "${2:-all}" ;;
    --help|-h)
        echo "Usage: $0 [build|push [variant]|ship [variant]]"
        echo "Variants: deb-nix, deb-apt, nixos-hm, all (default)"
        ;;
    *)           error "Unknown command: $1 (use: build, push, ship)" ;;
esac
