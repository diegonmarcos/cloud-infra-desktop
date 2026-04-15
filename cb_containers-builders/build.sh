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

    # Generate docker-deps.sh from cloud/config.json
    _cloud_config=""
    for _p in "$SCRIPT_DIR/../../cloud/config.json" "$SCRIPT_DIR/../../../cloud/config.json" "/root/git/cloud/config.json" "/workspace/config.json"; do
        [ -f "$_p" ] && { _cloud_config="$_p"; break; }
    done
    if [ -n "$_cloud_config" ]; then
        jq -r '"#!/bin/bash\nset -e\n\n# AUTO-GENERATED from cloud/config.json — DO NOT EDIT\n\napt-get update && apt-get install -y --no-install-recommends " + (.deps.docker_apt | join(" ")) + " && rm -rf /var/lib/apt/lists/*\nsed -i \"s/^# *\\(en_US.UTF-8\\)/\\1/\" /etc/locale.gen && locale-gen\n\nTF_VER=" + .deps.docker_binary.terraform + "\ncurl -sL \"https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_linux_amd64.zip\" -o /tmp/tf.zip\nunzip -o /tmp/tf.zip -d /usr/local/bin/ && rm /tmp/tf.zip\n\nRUST_VER=" + .deps.docker_binary.rust + "\ncurl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain ${RUST_VER}\nln -sf /root/.cargo/bin/* /usr/local/bin/"' "$_cloud_config" > "$DIST_DIR/docker-deps.sh"
        chmod +x "$DIST_DIR/docker-deps.sh"
        log "Generated docker-deps.sh from config.json"
    fi

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

    # Build args
    _build_args=""
    [ -n "${GITHUB_TOKEN:-}" ] && _build_args="--build-arg GITHUB_TOKEN=$GITHUB_TOKEN"

    # Multi-arch: local build uses native platform only, push uses buildx for all
    if echo "$_platform" | grep -q ","; then
        log "  Multi-arch: $_platform (local build uses native platform only)"
        DOCKER_BUILDKIT=1 $ENGINE build --network=host $_build_args -t "$_ghcr:latest" -f "$_dockerfile_path" "$DIST_DIR"
    elif [ -n "$_platform" ]; then
        DOCKER_BUILDKIT=1 $ENGINE build --network=host $_build_args --platform="$_platform" -t "$_ghcr:latest" -f "$_dockerfile_path" "$DIST_DIR"
    else
        DOCKER_BUILDKIT=1 $ENGINE build --network=host $_build_args -t "$_ghcr:latest" -f "$_dockerfile_path" "$DIST_DIR"
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

    # Pass GITHUB_TOKEN as build-arg for authenticated GitHub API
    _build_args=""
    [ -n "${GITHUB_TOKEN:-}" ] && _build_args="--build-arg GITHUB_TOKEN=$GITHUB_TOKEN"

    # Multi-arch: rebuild with --push (buildx can't push after --load for multi-platform)
    if echo "$_platform" | grep -q ","; then
        _dockerfile_path="$DIST_DIR/$(basename "$_dockerfile")"
        log "Step 3: PUSH (multi-arch buildx) — $_ghcr:latest"
        # Ensure a buildx builder with multi-platform support exists
        if ! $ENGINE buildx inspect multiarch >/dev/null 2>&1; then
            $ENGINE buildx create --name multiarch --driver docker-container --use 2>/dev/null || true
        fi
        $ENGINE buildx use multiarch 2>/dev/null || true
        $ENGINE buildx build --network=host $_build_args --platform="$_platform" -t "$_ghcr:latest" -f "$_dockerfile_path" "$DIST_DIR" --push
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
    _B="\033[1m"    # bold
    _D="\033[2m"    # dim
    _C="\033[36m"   # cyan
    _G="\033[32m"   # green
    _Y="\033[33m"   # yellow
    _M="\033[35m"   # magenta
    _R="\033[0m"    # reset

    printf "\n"
    printf "  ${_C}██████╗ ${_G}██╗   ██╗${_Y}██╗██╗     ${_M}██████╗ ${_R}${_D}██╗  ██╗${_R}\n"
    printf "  ${_C}██╔══██╗${_G}██║   ██║${_Y}██║██║     ${_M}██╔══██╗${_R}${_D}╚██╗██╔╝${_R}\n"
    printf "  ${_C}██████╔╝${_G}██║   ██║${_Y}██║██║     ${_M}██║  ██║${_R}${_D} ╚███╔╝ ${_R}  ${_B}BUILDx${_R}\n"
    printf "  ${_C}██╔══██╗${_G}██║   ██║${_Y}██║██║     ${_M}██║  ██║${_R}${_D} ██╔██╗ ${_R}  ${_D}CI/CD builder images (nix + docker + sops)${_R}\n"
    printf "  ${_C}██████╔╝${_G}╚██████╔╝${_Y}██║██████╗${_M}██████╔╝${_R}${_D}██╔╝ ██╗${_R}\n"
    printf "  ${_C}╚═════╝ ${_G} ╚═════╝ ${_Y}╚═╝╚═════╝${_M}╚═════╝ ${_R}${_D}╚═╝  ╚═╝${_R}\n"
    printf "\n"
    printf "  ${_D}────────────────────────────────────────────────────────${_R}\n"
    printf "\n"
    printf "  ${_B}COMMANDS${_R}\n"
    printf "    ${_C}a)${_R}  ${_B}ship${_R}              full pipeline: flake-build + image-build + image-push\n"
    printf "        ${_D}a0)${_R} flake-build       src/ + flake → dist/\n"
    printf "        ${_D}a1)${_R} image-build       build docker image locally\n"
    printf "        ${_D}a2)${_R} image-push        build + push to GHCR (multi-arch)\n"
    printf "    ${_G}b)${_R}  ${_B}run${_R}               pull + start container interactively\n"
    printf "        ${_D}b0)${_R} image-pull        pull latest image from GHCR\n"
    printf "        ${_D}b1)${_R} image-run         start container (no pull)\n"
    printf "    ${_Y}c)${_R}  ${_B}list${_R}              list running containers + local images + stats\n"
    printf "        ${_D}c0)${_R} list-containers   list running containers\n"
    printf "        ${_D}c1)${_R} list-images       list local images\n"
    printf "        ${_D}c2)${_R} container-stats   live resource usage\n"
    printf "\n"
    printf "  ${_B}IMAGES${_R}\n"
    _n=1
    for v in $(jq -r '.images | keys_unsorted[]' "$CONFIG"); do
        _desc=$(jq -r ".images.\"$v\".description" "$CONFIG")
        printf "    ${_M}%d)${_R} %-30s ${_D}%s${_R}\n" "$_n" "$v" "$_desc"
        _n=$(( _n + 1 ))
    done
    printf "\n"
    printf "  ${_B}PROFILES${_R}\n"
    printf "    ${_D}I)${_R}  User-Dev          ${_D}Desktop development environment${_R}\n"
    printf "    ${_D}II)${_R} Server-Dev        ${_D}Server/cloud operations environment${_R}\n"
    printf "\n"
    printf "  ${_D}────────────────────────────────────────────────────────${_R}\n"
    printf "  ${_B}Usage:${_R} $0 ${_C}<command>${_R} ${_M}<image|number>${_R}\n"
    printf "\n"
    printf "  ${_D}Examples:${_R}\n"
    printf "    $0 ${_C}ship${_R} ${_M}1${_R}                          ${_D}# ship cloud-builder-x-deb-nixhm${_R}\n"
    printf "    $0 ${_C}ship${_R} ${_M}cloud-builder-x-deb-nixhm${_R}  ${_D}# same, by name${_R}\n"
    printf "    $0 ${_C}ship${_R} ${_M}all${_R}                        ${_D}# ship all images${_R}\n"
    printf "    $0 ${_G}run${_R}  ${_M}1${_R}                          ${_D}# pull + shell${_R}\n"
    printf "    $0 ${_Y}c${_R}                              ${_D}# list everything${_R}\n"
    printf "\n"
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
