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
    # Prior runs use `cp -rL` on nix-store outputs (read-only mode 444 / 555).
    # The local copies retain those modes, so a plain `rm -rf` fails with
    # "Permission denied" on every file. Pre-chmod -R u+w restores write
    # permission on the directory tree before removal.
    [ -d "$DIST_DIR" ] && chmod -R u+w "$DIST_DIR" 2>/dev/null
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"

    # Copy all src/ files (Dockerfiles, flake, entrypoint, deps, etc.).
    # Skip ./result — that's the transient nix-build symlink (gitignored).
    # cp -rL would dereference it and drag the OLD nix-store closure into
    # dist/result/, masking source edits. The fresh out path is captured
    # below by `nix build --no-link --print-out-paths`, which is the
    # correct + canonical compose/json source.
    for _src_entry in "$SRC_DIR"/*; do
        case "$(basename "$_src_entry")" in
            result|result-*) continue ;;
        esac
        cp -rL "$_src_entry" "$DIST_DIR/"
    done
    unset _src_entry

    # Generate compose files from flake → overwrite into dist/
    cd "$SRC_DIR"
    nix build --no-link --print-out-paths 2>/dev/null | while read -r path; do
        cp -rL "$path"/*.yaml "$DIST_DIR/" 2>/dev/null || true
        cp -rL "$path"/*.json "$DIST_DIR/" 2>/dev/null || true
    done

    # Generate docker-deps.sh from cloud/config.json
    # Env override wins: set CLOUD_CONFIG=/path/to/config.json to point explicitly.
    _cloud_config=""
    if [ -n "${CLOUD_CONFIG:-}" ] && [ -f "$CLOUD_CONFIG" ]; then
        _cloud_config="$CLOUD_CONFIG"
    else
        for _p in "$SCRIPT_DIR/../../cloud/config.json" "$SCRIPT_DIR/../../../cloud/config.json" "/root/git/cloud/config.json" "/workspace/config.json" "$SCRIPT_DIR/../cloud-repo/config.json"; do
            [ -f "$_p" ] && { _cloud_config="$_p"; break; }
        done
    fi
    if [ -n "$_cloud_config" ]; then
        # Generate docker-deps.sh in two segments:
        #   1. apt + locale + terraform + rust   — driven by .deps.docker_apt + .deps.docker_binary
        #   2. npm globals                        — driven by .deps.docker_npm (data-driven, FIRE rule 4)
        #      Skips entries whose key starts with "_" (json-doc convention).
        #      Each entry emits `npm install -g <pkg>@<version>` so binaries
        #      land on $PATH without runtime install.
        # npm globals: pin prefix to /usr/local so binaries land in a path
        # that's unconditionally on PATH for every consumer of the image.
        # Default prefix for the nix-installed node ends up at
        # /root/.nix-profile or ~/.npm-global — neither is in the runtime
        # ENTRYPOINT's PATH for cloud-builder consumers, so `command -v
        # wrangler` returns false and ship-terraform aborts with
        # "wrangler not on PATH inside cloud-builder image". Setting
        # `npm config set prefix /usr/local` ONCE before the install loop
        # makes every global bin show up under /usr/local/bin/ — mirrors
        # how the rust step puts cargo bins on /usr/local/bin via ln -sf.
        jq -r '"#!/bin/bash\nset -e\n\n# AUTO-GENERATED from cloud/config.json — DO NOT EDIT\n\napt-get update && apt-get install -y --no-install-recommends " + (.deps.docker_apt | join(" ")) + " && rm -rf /var/lib/apt/lists/*\nsed -i \"s/^# *\\(en_US.UTF-8\\)/\\1/\" /etc/locale.gen && locale-gen\n\nTF_VER=" + .deps.docker_binary.terraform + "\ncurl -sL \"https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_linux_amd64.zip\" -o /tmp/tf.zip\nunzip -o /tmp/tf.zip -d /usr/local/bin/ && rm /tmp/tf.zip\n\nRUST_VER=" + .deps.docker_binary.rust + "\ncurl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain ${RUST_VER}\nln -sf /root/.cargo/bin/* /usr/local/bin/\n\n# ── npm globals (from .deps.docker_npm) ──\nnpm config set prefix /usr/local\n" + (.deps.docker_npm // {} | to_entries | map(select(.key | startswith("_") | not)) | map("npm install -g " + .key + "@" + .value) | join("\n"))' "$_cloud_config" > "$DIST_DIR/docker-deps.sh"
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

# Locate cloud-data-runners.json — single source of truth for arch → runner.
# Search order matches the cloud engine so the same pattern works in GHA,
# locally, and in the cloud-builder container.
_find_runners_json() {
    for _p in \
        "${CLOUD_DATA_RUNNERS_JSON:-}" \
        "$SCRIPT_DIR/../../cloud/2_configs/dist/cloud-data-runners.json" \
        "$SCRIPT_DIR/../../../cloud/2_configs/dist/cloud-data-runners.json" \
        "$SCRIPT_DIR/../cloud-repo/2_configs/dist/cloud-data-runners.json" \
        "${GITHUB_WORKSPACE:-}/cloud-repo/2_configs/dist/cloud-data-runners.json" \
        "/root/git/cloud/2_configs/dist/cloud-data-runners.json"; do
        [ -n "$_p" ] && [ -f "$_p" ] && { echo "$_p"; return 0; }
    done
    return 1
}

# Build + push a single arch image on the runner declared for that arch.
# Writes the produced tag to _LAST_ARCH_TAG so caller can collect it without
# having to parse mixed log/stdout. Never uses QEMU emulation.
_LAST_ARCH_TAG=""
_build_push_arch() {
    _ghcr="$1"; _arch="$2"; _dockerfile_path="$3"; _sha="$4"; _runners_json="$5"
    _runner_type=$(jq -r --arg a "$_arch" '.runners[$a].type // empty' "$_runners_json")
    _runner_host=$(jq -r --arg a "$_arch" '.runners[$a].host // empty' "$_runners_json")
    _tag="$_ghcr:$_sha-$_arch"
    _LAST_ARCH_TAG=""

    [ -z "$_runner_type" ] && { log_error "No runner declared for arch=$_arch in cloud-data-runners.json"; return 1; }

    _build_args=""
    [ -n "${GITHUB_TOKEN:-}" ] && _build_args="--build-arg GITHUB_TOKEN=$GITHUB_TOKEN"

    case "$_runner_type" in
        local)
            log "Native build $_arch → local (runner=$(uname -m))"
            DOCKER_BUILDKIT=1 $ENGINE build --network=host $_build_args \
                --platform "linux/$_arch" \
                -t "$_tag" -f "$_dockerfile_path" "$DIST_DIR" || return 1
            $ENGINE push "$_tag" || return 1
            ;;
        ssh)
            [ -z "$_runner_host" ] && { log_error "runners[$_arch].host missing in cloud-data-runners.json"; return 1; }
            log "Native build $_arch → ssh://$_runner_host (no QEMU)"
            _remote_ctx="/tmp/cb-build-$_arch-$$"
            ssh -o StrictHostKeyChecking=accept-new "$_runner_host" "mkdir -p $_remote_ctx" || return 1
            rsync -azL --delete -e "ssh -o StrictHostKeyChecking=accept-new" \
                "$DIST_DIR/" "$_runner_host:$_remote_ctx/" || return 1
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                ssh "$_runner_host" "echo '$GITHUB_TOKEN' | docker login ghcr.io -u '${GITHUB_ACTOR:-diegonmarcos}' --password-stdin" >/dev/null || return 1
            fi
            ssh "$_runner_host" "cd $_remote_ctx && DOCKER_BUILDKIT=1 docker build --network=host $_build_args --platform linux/$_arch -t '$_tag' -f '$(basename "$_dockerfile_path")' . && docker push '$_tag' && rm -rf $_remote_ctx" || return 1
            ;;
        *)
            log_error "Unknown runner type '$_runner_type' for arch=$_arch (valid: local, ssh)"
            return 1
            ;;
    esac
    log "Built + pushed $_tag"
    _LAST_ARCH_TAG="$_tag"
    return 0
}

# log_error — same shape as log but marks the line as error (goes to stderr).
log_error() { printf "${RED}[!]${NC} %s\n" "$1" >&2; }

_docker_push() {
    _variant="$1"
    _ghcr=$(jq -r ".images.\"$_variant\".ghcr" "$CONFIG")
    _platform=$(jq -r ".images.\"$_variant\".platform // empty" "$CONFIG")
    _dockerfile=$(jq -r ".images.\"$_variant\".dockerfile" "$CONFIG")
    [ "$_ghcr" = "null" ] && { error "Unknown variant: $_variant"; }

    _dockerfile_path="$DIST_DIR/$(basename "$_dockerfile")"
    _sha="${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo local)}"

    _runners_json=$(_find_runners_json) || error "cloud-data-runners.json not found — cannot resolve runners (no QEMU fallback)"
    log "Runners source: $_runners_json"

    # Parse platform list: "linux/amd64,linux/arm64" → arch tokens
    _arches=$(echo "$_platform" | tr ',' '\n' | sed 's|linux/||g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')
    [ -z "$_arches" ] && error "$_variant: no platform declared in build.json"

    # Build + push each arch on its declared runner (native, no QEMU)
    # Collect per-arch tags via _LAST_ARCH_TAG (no stdout-capture — keeps logs
    # and return values separate). Fail loudly if any arch fails.
    _arch_tags=""
    for _arch in $_arches; do
        if ! _build_push_arch "$_ghcr" "$_arch" "$_dockerfile_path" "$_sha" "$_runners_json"; then
            error "arch=$_arch build failed — refusing to push a partial multi-arch manifest"
        fi
        _arch_tags="$_arch_tags $_LAST_ARCH_TAG"
    done

    # Stitch per-arch images into a multi-arch manifest for :latest and :$sha
    # --amend overwrites any stale manifest from previous runs.
    log "Step 3: MANIFEST — $_ghcr:latest → [$_arch_tags ]"
    DOCKER_CLI_EXPERIMENTAL=enabled $ENGINE manifest create --amend "$_ghcr:latest" $_arch_tags
    DOCKER_CLI_EXPERIMENTAL=enabled $ENGINE manifest push --purge "$_ghcr:latest"
    DOCKER_CLI_EXPERIMENTAL=enabled $ENGINE manifest create --amend "$_ghcr:$_sha" $_arch_tags
    DOCKER_CLI_EXPERIMENTAL=enabled $ENGINE manifest push --purge "$_ghcr:$_sha"
    log "Pushed multi-arch manifest: $_ghcr:latest ($_ghcr:$_sha)"
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
    shift
    _cmd="${*:-bash}"
    _ghcr=$(jq -r ".images.\"$_variant\".ghcr" "$CONFIG")

    log "Running $_ghcr:latest — $_cmd"
    # Use compose if available, else docker run
    if [ -f "$DIST_DIR/docker/compose.yaml" ]; then
        docker compose -f "$DIST_DIR/docker/compose.yaml" run --rm cloud-builder $_cmd
    else
        docker run -it --rm --network=host \
            -v /var/run/docker.sock:/var/run/docker.sock \
            "$_ghcr:latest" $_cmd
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
    b1|image-run)    step_run "$(resolve_variant "${2:-1}")" "${@:3}" ;;
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
