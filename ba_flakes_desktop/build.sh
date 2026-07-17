#!/bin/sh
# ============================================================================
# Diego's Dev Environment - Build Script
# ============================================================================
# POSIX-compliant build script with TUI and CLI support
#
# Usage:
#   ./build.sh              # Launch TUI menu
#   ./build.sh <command>    # Run specific command
#   ./build.sh --help       # Show help
#
# Config: build.json
# Logs:   build.log
# ============================================================================

set -eu

# Ensure PATH includes nix profile + local bins (shell PATH may be broken)
export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Skip guardrail wrappers entirely — build.sh is the sanctioned interface
export BUILDSH_GUARDRAIL=1

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/build.json"
LOG_FILE="$SCRIPT_DIR/build.log"
SRC_DIR="$SCRIPT_DIR/src"
DIST_DIR="$SCRIPT_DIR/dist"
CONTAINER_DIR="$SCRIPT_DIR/src/container"
# Single source of truth for the GHCR layered-HM-cache subscription (image,
# tag, activation-path label). Shared with programs/hm-auto-update.nix so the
# poll timer and the switch/ci-build engine agree on ONE image + label — never
# hardcoded twice. Read via hmcfg() below.
HM_AUTO_CFG="$SRC_DIR/modules/programs/hm-auto-update.json"
# GitHub-Pages nix binary cache config (incremental streaming transport — the
# only deploy path that works on the disk-full box). See nix-cache.json.
NIX_CACHE_CFG="$SRC_DIR/modules/nix-cache.json"

# Age key — dotfile symlink from vault/build.sh setup system, sops-nix fallback
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

# Colors (ANSI escape codes)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

log() {
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "[%s] %s\n" "$timestamp" "$*" >> "$LOG_FILE"
}

log_info() {
    log "INFO: $*"
    printf "${BLUE}[INFO]${NC} %s\n" "$*"
}

log_success() {
    log "SUCCESS: $*"
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$*"
}

log_warn() {
    log "WARN: $*"
    printf "${YELLOW}[WARN]${NC} %s\n" "$*"
}

log_error() {
    log "ERROR: $*"
    printf "${RED}[ERROR]${NC} %s\n" "$*" >&2
}

log_header() {
    log "========== $* =========="
    printf "\n${BOLD}${CYAN}=== %s ===${NC}\n\n" "$*"
}

# ============================================================================
# PERF — step timing library
# ============================================================================
# Uses epoch seconds (POSIX). Tracks per-step and total elapsed time.
#
#   perf_start "command-name"     — begin total timer, print header
#   perf_step  "step label"      — end previous step (if any), start new one
#   perf_end                     — end last step, print summary table

_PERF_CMD=""
_PERF_TOTAL_START=""
_PERF_STEP_START=""
_PERF_STEP_NAME=""
_PERF_STEPS=""

_epoch_ms() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import time; print(int(time.time()*1000))"
    elif date +%s%N >/dev/null 2>&1; then
        echo $(( $(date +%s%N) / 1000000 ))
    else
        echo "$(date +%s)000"
    fi
}

_fmt_duration() {
    _ms=$1
    if [ "$_ms" -ge 60000 ]; then
        _min=$(( _ms / 60000 ))
        _sec=$(( (_ms % 60000) / 1000 ))
        printf "%dm %ds" "$_min" "$_sec"
    elif [ "$_ms" -ge 1000 ]; then
        _sec=$(( _ms / 1000 ))
        _frac=$(( (_ms % 1000) / 100 ))
        printf "%d.%ds" "$_sec" "$_frac"
    else
        printf "%dms" "$_ms"
    fi
}

_perf_dots() {
    _label="$1"
    _width=36
    _len=${#_label}
    _pad=$(( _width - _len ))
    [ "$_pad" -lt 2 ] && _pad=2
    printf "%s " "$_label"
    _i=0
    while [ "$_i" -lt "$_pad" ]; do printf "."; _i=$((_i+1)); done
    printf " "
}

perf_start() {
    _PERF_CMD="$1"
    _PERF_TOTAL_START=$(_epoch_ms)
    _PERF_STEP_START=""
    _PERF_STEP_NAME=""
    _PERF_STEPS=""
    printf "${BOLD}${CYAN}[PERF]${NC} Timer started: ${BOLD}%s${NC}\n" "$_PERF_CMD"
    log "PERF: start $1"
}

perf_step() {
    _now=$(_epoch_ms)
    if [ -n "$_PERF_STEP_START" ] && [ -n "$_PERF_STEP_NAME" ]; then
        _elapsed=$(( _now - _PERF_STEP_START ))
        _dur=$(_fmt_duration "$_elapsed")
        printf "${YELLOW}[PERF]${NC} ─ $(_perf_dots "$_PERF_STEP_NAME")${GREEN}%s${NC}\n" "$_dur"
        log "PERF: $_PERF_STEP_NAME = $_dur"
        _PERF_STEPS="${_PERF_STEPS}${_elapsed} ${_PERF_STEP_NAME}
"
    fi
    _PERF_STEP_NAME="$1"
    _PERF_STEP_START=$(_epoch_ms)
}

perf_end() {
    _now=$(_epoch_ms)
    if [ -n "$_PERF_STEP_START" ] && [ -n "$_PERF_STEP_NAME" ]; then
        _elapsed=$(( _now - _PERF_STEP_START ))
        _dur=$(_fmt_duration "$_elapsed")
        printf "${YELLOW}[PERF]${NC} ─ $(_perf_dots "$_PERF_STEP_NAME")${GREEN}%s${NC}\n" "$_dur"
        log "PERF: $_PERF_STEP_NAME = $_dur"
        _PERF_STEPS="${_PERF_STEPS}${_elapsed} ${_PERF_STEP_NAME}
"
    fi
    _total=$(( _now - _PERF_TOTAL_START ))
    _total_dur=$(_fmt_duration "$_total")
    printf "${BOLD}${CYAN}[PERF]${NC} ${BOLD}══ Total: %s ══ %s${NC}\n" "$_PERF_CMD" "$_total_dur"
    log "PERF: TOTAL $_PERF_CMD = $_total_dur"
    _PERF_CMD=""
    _PERF_TOTAL_START=""
    _PERF_STEP_START=""
    _PERF_STEP_NAME=""
    _PERF_STEPS=""
}

# ============================================================================
# CONFIG FUNCTIONS (requires jq)
# ============================================================================

config_get() {
    if command -v jq >/dev/null 2>&1; then
        jq -r "$1" "$CONFIG_FILE" 2>/dev/null || echo ""
    else
        log_warn "jq not found, using defaults"
        echo ""
    fi
}

# Read a value from the shared HM-auto-update config (single source of truth
# for the GHCR cache image name, tag, and activation-path label). Falls back to
# the hardcoded literals ONLY if jq or the file is unavailable, so ci-build on a
# minimal runner still works.
hmcfg() {
    if command -v jq >/dev/null 2>&1 && [ -f "$HM_AUTO_CFG" ]; then
        jq -r "$1" "$HM_AUTO_CFG" 2>/dev/null || echo ""
    else
        echo ""
    fi
}
hm_cache_image() { _v="$(hmcfg .image)"; [ -n "$_v" ] && [ "$_v" != "null" ] && echo "$_v" || echo "ghcr.io/diegonmarcos/unix-hm-cache"; }
hm_cache_label() { _v="$(hmcfg .activation_label)"; [ -n "$_v" ] && [ "$_v" != "null" ] && echo "$_v" || echo "com.diegonmarcos.activation-path"; }

get_default_user() {
    val=$(config_get '.defaults.user')
    printf "%s" "${val:-diego}"
}

get_default_host() {
    val=$(config_get '.defaults.host')
    printf "%s" "${val:-surface}"
}

get_image_name() {
    val=$(config_get '.container.image_name')
    printf "%s" "${val:-diego-dev}"
}

get_image_tag() {
    val=$(config_get '.container.image_tag')
    printf "%s" "${val:-latest}"
}

# ============================================================================
# DEPENDENCY CHECKS
# ============================================================================

check_nix() {
    if ! command -v nix >/dev/null 2>&1; then
        log_error "Nix not found"
        printf "Install with: curl -L https://nixos.org/nix/install | sh\n"
        return 1
    fi
    return 0
}

check_home_manager() {
    if ! command -v home-manager >/dev/null 2>&1; then
        log_warn "home-manager not found, will use nix run"
        return 1
    fi
    return 0
}

check_container_runtime() {
    if command -v podman >/dev/null 2>&1; then
        printf "podman"
    elif command -v docker >/dev/null 2>&1; then
        printf "docker"
    else
        log_error "No container runtime found (podman or docker)"
        return 1
    fi
}

check_distrobox() {
    if ! command -v distrobox >/dev/null 2>&1; then
        log_error "distrobox not found"
        printf "Install: curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local\n"
        return 1
    fi
    return 0
}

# ============================================================================
# NIX FUNCTIONS
# ============================================================================

nix_install() {
    log_header "Installing Nix"

    if check_nix; then
        log_info "Nix already installed"
        nix --version
        return 0
    fi

    log_info "Installing Nix..."
    curl -L https://nixos.org/nix/install | sh -s -- --daemon

    log_info "Enabling flakes..."
    mkdir -p ~/.config/nix
    echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

    log_success "Nix installed. Please restart your shell."
}

nix_switch() {
    host="${1:-$(get_default_host)}"
    user="${2:-$(get_default_user)}"
    flake_ref="$SRC_DIR#${user}@${host}"

    log_header "Switching to $flake_ref"
    perf_start "switch"

    if ! check_nix; then
        return 1
    fi

    # Stage dirty files so nix flake evaluation sees changes
    perf_step "git stage"
    if command -v git >/dev/null 2>&1; then
        dirty=$(git -C "$SRC_DIR" status --porcelain 2>/dev/null || true)
        if [ -n "$dirty" ]; then
            log_info "Staging dirty files for flake evaluation..."
            git -C "$SRC_DIR" add -A 2>/dev/null || true
        fi
    fi

    # ── home-manager-always-wins backup policy ────────────────────────────
    # 2026-04-28: prior `-b backup` (fixed extension) failed when a previous
    # backup already existed at the target path:
    #   "Existing file '~/.config/plasma-localerc.backup' would be clobbered
    #    by backing up '~/.config/plasma-localerc'"
    # Engine fix: use a UNIQUE timestamp extension on every switch so home-
    # manager never collides with a prior backup. Old backups age out via
    # the 7-day prune below, so clutter doesn't accumulate forever.
    perf_step "clean stale hm-backups"
    # Prune hm-backup-* files older than 7 days across the home tree (depth
    # bounded — KDE/typical config sits within 4 levels). Old fixed-name
    # `*.backup` files (legacy) also pruned to unblock the very first run
    # of this version of the engine.
    command find "$HOME" -maxdepth 4 \
        \( -name "*.hm-backup-*" -mtime +7 -o -name "*.backup" \) \
        -type f -delete 2>/dev/null || true

    perf_step "home-manager switch"
    log_info "Applying Home Manager configuration..."

    # Force nix to re-evaluate by touching flake.nix (busts eval cache)
    touch "$SRC_DIR/flake.nix" 2>/dev/null || true

    # Unique backup extension per switch — guarantees home-manager always
    # wins, never blocked by a stale backup at the same path. Format:
    # hm-backup-YYYYMMDD-HHMMSS. The 7-day prune above keeps clutter low.
    HM_BACKUP_EXT="hm-backup-$(date +%Y%m%d-%H%M%S)"
    log_info "home-manager backup extension: $HM_BACKUP_EXT"

    # KDE progress popup (programs/nix-switch-progress.nix) — transparent when
    # absent or non-graphical (SSH/CI): falls back to a plain passthrough exec.
    # NSP_SRC_DIR/NSP_FLAKE_ATTR feed the wrapper's git-diff + closure-size panel.
    _nsp=""
    command -v nix-switch-progress-wrap >/dev/null 2>&1 && _nsp="nix-switch-progress-wrap"
    export NSP_SRC_DIR="$SRC_DIR"
    export NSP_FLAKE_ATTR="$SRC_DIR#homeConfigurations.\"${user}@${host}\".activationPackage"

    # Capture exit code from the actual command, not tee. NSP_LOG_FILE lets
    # the wrapper's own internal tee write $LOG_FILE (avoids double-teeing
    # when the wrapper is active — see nix-switch-progress.nix).
    _rc_file=$(mktemp)
    if check_home_manager 2>/dev/null; then
        if [ -n "$_nsp" ]; then
            { NSP_LOG_FILE="$LOG_FILE" $_nsp home-manager switch --impure -b "$HM_BACKUP_EXT" --flake "$flake_ref"; echo $? > "$_rc_file"; }
        else
            { home-manager switch --impure -b "$HM_BACKUP_EXT" --flake "$flake_ref" 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
        fi
    else
        if [ -n "$_nsp" ]; then
            { NSP_LOG_FILE="$LOG_FILE" $_nsp nix run home-manager -- switch --impure -b "$HM_BACKUP_EXT" --flake "$flake_ref"; echo $? > "$_rc_file"; }
        else
            { nix run home-manager -- switch --impure -b "$HM_BACKUP_EXT" --flake "$flake_ref" 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
        fi
    fi
    exit_code=$(cat "$_rc_file" 2>/dev/null)
    rm -f "$_rc_file"

    # If exit code capture failed, treat as error (flakes always win)
    exit_code=${exit_code:-1}

    if [ "$exit_code" -ne 0 ]; then
        log_error "Configuration failed with exit code $exit_code"
        log_info "Check $LOG_FILE for details"
        perf_end
        return $exit_code
    fi

    perf_end
    log_success "Configuration applied: $flake_ref"

    # Show cached drift summary (instant, no network)
    if command -v nix-drift >/dev/null 2>&1; then
        nix-drift drift --cached 2>/dev/null || true
        # Refresh cache in background for next switch
        nix-drift refresh &
    fi
}

nix_build() {
    # Dry build — evaluate the flake's activationPackage and produce a
    # ./src/result symlink WITHOUT activating home-manager. Used to verify
    # changes (closure equality, eval errors) before a real `switch`.
    host="${1:-$(get_default_host)}"
    user="${2:-$(get_default_user)}"
    flake_ref="$SRC_DIR#${user}@${host}"

    log_header "Building (no activate) $flake_ref"
    perf_start "build"

    if ! check_nix; then
        return 1
    fi

    perf_step "git stage"
    if command -v git >/dev/null 2>&1; then
        dirty=$(git -C "$SRC_DIR" status --porcelain 2>/dev/null || true)
        if [ -n "$dirty" ]; then
            log_info "Staging dirty files for flake evaluation..."
            git -C "$SRC_DIR" add -A 2>/dev/null || true
        fi
    fi

    # Force nix to re-evaluate by touching flake.nix (busts eval cache)
    touch "$SRC_DIR/flake.nix" 2>/dev/null || true

    perf_step "home-manager build"
    log_info "Building Home Manager activation package (no switch)..."

    cd "$SRC_DIR"
    _rc_file=$(mktemp)
    if check_home_manager 2>/dev/null; then
        { home-manager build --impure --flake "$flake_ref" 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
    else
        { nix run home-manager -- build --impure --flake "$flake_ref" 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
    fi
    exit_code=$(cat "$_rc_file" 2>/dev/null)
    rm -f "$_rc_file"
    exit_code=${exit_code:-1}

    if [ "$exit_code" -ne 0 ]; then
        log_error "Build failed with exit code $exit_code"
        log_info "Check $LOG_FILE for details"
        perf_end
        return $exit_code
    fi

    perf_end
    if [ -L "$SRC_DIR/result" ]; then
        log_success "Built: $(readlink "$SRC_DIR/result")"
    else
        log_success "Build complete (no result symlink — check log)"
    fi
}

nix_update() {
    log_header "Updating Flake Inputs"

    if ! check_nix; then
        return 1
    fi

    cd "$SRC_DIR"
    log_info "Updating flake.lock..."

    _rc_file=$(mktemp)
    { nix flake update 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
    exit_code=$(cat "$_rc_file" 2>/dev/null)
    rm -f "$_rc_file"

    # If exit code capture failed, treat as error (flakes always win)
    exit_code=${exit_code:-1}

    if [ "$exit_code" -ne 0 ]; then
        log_error "Flake update failed with exit code $exit_code"
        return $exit_code
    fi

    log_success "Flake inputs updated"
}

nix_show() {
    log_header "Flake Outputs"

    if ! check_nix; then
        return 1
    fi

    cd "$SRC_DIR"
    nix flake show
}

nix_develop() {
    log_header "Entering Dev Shell"

    if ! check_nix; then
        return 1
    fi

    cd "$SRC_DIR"
    nix develop
}

# ============================================================================
# CONTAINER FUNCTIONS
# ============================================================================

container_build() {
    image_type="${1:-full}"

    log_header "Building Container Image ($image_type)"

    if ! check_nix; then
        return 1
    fi

    cd "$SRC_DIR"
    mkdir -p "$DIST_DIR"

    case "$image_type" in
        full)
            log_info "Building full image..."
            nix build .#container -o "$DIST_DIR/container-full" 2>&1 | tee -a "$LOG_FILE"
            ;;
        minimal)
            log_info "Building minimal image..."
            nix build .#container-minimal -o "$DIST_DIR/container-minimal" 2>&1 | tee -a "$LOG_FILE"
            ;;
        *)
            log_error "Unknown image type: $image_type (use: full, minimal)"
            return 1
            ;;
    esac

    log_success "Image built: $DIST_DIR/container-$image_type"
    printf "\nLoad with: %s load < %s/container-%s\n" "$(check_container_runtime)" "$DIST_DIR" "$image_type"
}

container_load() {
    image_type="${1:-full}"

    log_header "Loading Container Image ($image_type)"

    runtime=$(check_container_runtime) || return 1

    image_file="$DIST_DIR/container-$image_type"

    if [ ! -e "$image_file" ]; then
        log_error "No image found at $image_file"
        log_info "Run: ./build.sh container-build $image_type"
        return 1
    fi

    log_info "Loading image with $runtime..."
    $runtime load < "$image_file" 2>&1 | tee -a "$LOG_FILE"

    log_success "Image loaded"
}

container_run() {
    image_type="${1:-full}"

    log_header "Running Container"

    runtime=$(check_container_runtime) || return 1

    image_name=$(get_image_name)
    image_tag=$(get_image_tag)

    if [ "$image_type" = "minimal" ]; then
        image_name="${image_name}-minimal"
    fi

    log_info "Starting ${image_name}:${image_tag} with $runtime..."

    $runtime run -it --rm \
        --name diego-dev-temp \
        --hostname diego-dev \
        --user 1000:1000 \
        -e TERM=xterm-256color \
        -e HOME=/home/diego \
        -v "$HOME/Documents/Git:/home/diego/projects:z" \
        -v "$HOME/.ssh:/home/diego/.ssh:ro,z" \
        -w /home/diego \
        "${image_name}:${image_tag}"
}

container_push() {
    registry="${1:-}"

    log_header "Pushing Container Image"

    runtime=$(check_container_runtime) || return 1

    image_name=$(get_image_name)
    image_tag=$(get_image_tag)

    if [ -z "$registry" ]; then
        log_error "Registry required: ./build.sh container-push ghcr.io/username"
        return 1
    fi

    full_image="${registry}/${image_name}:${image_tag}"

    log_info "Tagging ${image_name}:${image_tag} -> $full_image"
    $runtime tag "${image_name}:${image_tag}" "$full_image"

    log_info "Pushing to $registry..."
    $runtime push "$full_image" 2>&1 | tee -a "$LOG_FILE"

    log_success "Pushed: $full_image"
}

# ============================================================================
# COMPOSE FUNCTIONS
# ============================================================================

compose_up() {
    log_header "Starting Compose Services"

    runtime=$(check_container_runtime) || return 1
    cd "$CONTAINER_DIR"

    if [ "$runtime" = "podman" ] && command -v podman-compose >/dev/null 2>&1; then
        log_info "Using podman-compose..."
        podman-compose up -d 2>&1 | tee -a "$LOG_FILE"
    elif [ "$runtime" = "docker" ]; then
        log_info "Using docker compose..."
        docker compose up -d 2>&1 | tee -a "$LOG_FILE"
    else
        log_error "No compose tool found"
        return 1
    fi

    log_success "Services started"
    printf "\nEnter with: %s exec dev fish\n" "$runtime"
}

compose_down() {
    log_header "Stopping Compose Services"

    runtime=$(check_container_runtime) || return 1
    cd "$CONTAINER_DIR"

    if [ "$runtime" = "podman" ] && command -v podman-compose >/dev/null 2>&1; then
        podman-compose down 2>&1 | tee -a "$LOG_FILE"
    elif [ "$runtime" = "docker" ]; then
        docker compose down 2>&1 | tee -a "$LOG_FILE"
    fi

    log_success "Services stopped"
}

compose_shell() {
    runtime=$(check_container_runtime) || return 1
    cd "$CONTAINER_DIR"

    if [ "$runtime" = "podman" ] && command -v podman-compose >/dev/null 2>&1; then
        podman-compose exec dev fish
    elif [ "$runtime" = "docker" ]; then
        docker compose exec dev fish
    fi
}

# ============================================================================
# DISTROBOX FUNCTIONS
# ============================================================================

distrobox_create() {
    box_name="${1:-diego-dev}"

    log_header "Creating Distrobox: $box_name"

    check_distrobox || return 1

    image_name=$(get_image_name)
    image_tag=$(get_image_tag)

    log_info "Creating distrobox from ${image_name}:${image_tag}..."

    distrobox create \
        --name "$box_name" \
        --image "${image_name}:${image_tag}" \
        --home "$HOME" \
        --yes 2>&1 | tee -a "$LOG_FILE"

    log_success "Distrobox created: $box_name"
    printf "\nEnter with: distrobox enter %s\n" "$box_name"
}

distrobox_enter() {
    box_name="${1:-diego-dev}"
    check_distrobox || return 1
    distrobox enter "$box_name"
}

distrobox_remove() {
    box_name="${1:-diego-dev}"
    check_distrobox || return 1

    log_info "Removing distrobox: $box_name"
    distrobox rm "$box_name" --force 2>&1 | tee -a "$LOG_FILE"
    log_success "Distrobox removed"
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

clean() {
    log_header "Cleaning Build Artifacts"
    perf_start "clean"

    # Snapshot disk usage before
    _df_before=$(df -k /nix/store 2>/dev/null | awk 'NR==2{print $3}')
    log_info "Disk before: $(df -h /nix/store 2>/dev/null | awk 'NR==2{printf "%s used / %s avail", $3, $4}')"

    # 1. Remove result symlinks
    perf_step "remove symlinks"
    log_info "Removing Nix result symlinks..."
    rm -f "$SRC_DIR/result" "$SRC_DIR/result-*"

    # 2. Trim home-manager generations (keep last 3)
    perf_step "trim hm generations"
    log_info "Trimming home-manager generations (keep last 3)..."
    nix-env --delete-generations +3 2>&1 || true

    # 3. Garbage collect unreferenced store paths
    perf_step "nix-collect-garbage"
    log_info "Nix garbage collection..."
    nix-collect-garbage 2>&1 | tee -a "$LOG_FILE"

    # 4. Optimise store (deduplicate via hardlinks)
    perf_step "nix store optimise"
    log_info "Optimising nix store (dedup)..."
    nix store optimise 2>&1 | tee -a "$LOG_FILE"

    # 5. Clean nix eval/build caches
    perf_step "clear eval cache"
    if [ -d "$HOME/.cache/nix" ]; then
        _cache_size=$(du -sh "$HOME/.cache/nix" 2>/dev/null | awk '{print $1}')
        log_info "Clearing nix eval cache ($_cache_size)..."
        rm -rf "$HOME/.cache/nix"
    fi

    perf_end

    # Report savings
    _df_after=$(df -k /nix/store 2>/dev/null | awk 'NR==2{print $3}')
    log_info "Disk after:  $(df -h /nix/store 2>/dev/null | awk 'NR==2{printf "%s used / %s avail", $3, $4}')"

    if [ -n "$_df_before" ] && [ -n "$_df_after" ]; then
        _saved_kb=$(( _df_before - _df_after ))
        if [ "$_saved_kb" -gt 1048576 ]; then
            _saved="$(( _saved_kb / 1048576 ))G"
        elif [ "$_saved_kb" -gt 1024 ]; then
            _saved="$(( _saved_kb / 1024 ))M"
        else
            _saved="${_saved_kb}K"
        fi
        log_success "Cleanup complete — freed $_saved"
    else
        log_success "Cleanup complete"
    fi
}

status() {
    log_header "System Status"

    printf "${BOLD}Nix:${NC} "
    if check_nix 2>/dev/null; then
        nix --version
    else
        printf "Not installed\n"
    fi

    printf "${BOLD}Home Manager:${NC} "
    if check_home_manager 2>/dev/null; then
        home-manager --version 2>/dev/null || printf "Installed\n"
    else
        printf "Not installed (will use nix run)\n"
    fi

    printf "${BOLD}Container Runtime:${NC} "
    runtime=$(check_container_runtime 2>/dev/null) && printf "%s\n" "$runtime" || printf "Not found\n"

    printf "${BOLD}Distrobox:${NC} "
    if check_distrobox 2>/dev/null; then
        distrobox version 2>/dev/null || printf "Installed\n"
    else
        printf "Not installed\n"
    fi

    printf "\n${BOLD}Config:${NC} %s\n" "$CONFIG_FILE"
    printf "${BOLD}Log:${NC} %s\n" "$LOG_FILE"
    printf "${BOLD}Source:${NC} %s\n" "$SRC_DIR"
}

view_log() {
    if [ -f "$LOG_FILE" ]; then
        ${PAGER:-less} "$LOG_FILE"
    else
        log_info "No log file found"
    fi
}

clear_log() {
    : > "$LOG_FILE"
    log_info "Log file cleared"
}

# ============================================================================
# REMOTE BUILD (GHA x86) + LOCAL ACTIVATE — never run the freeze-prone eval locally
# ============================================================================
# The full Plasma home-manager config is a heavy eval (KDE) that over-commits
# RAM on the 8GB Surface and can thrash into a freeze. So the eval+build runs on
# a GHA x86 runner (`ci-build`), and the laptop only IMPORTS the prebuilt closure
# and runs its activate script (`pull`) — no eval, cannot freeze. Secrets are
# decrypted at activation on the device, so the GHA build needs none.

# ci-build — run on a GHA ubuntu-latest (x86) runner. Build the home-manager
# activationPackage and export its closure as a zstd tarball into dist-ci/.
cmd_ci_build() {
    log_header "CI: build + export home-manager closure"
    check_nix || return 1
    _host="${1:-surface-plasma}"; _user="${2:-diego}"
    _attr="homeConfigurations.\"${_user}@${_host}\".activationPackage"
    _out="$SCRIPT_DIR/dist-ci"
    rm -rf "$_out"; mkdir -p "$_out"

    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        log_info "Freeing GHA runner disk..."
        sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
                    /opt/hostedtoolcache/CodeQL /usr/local/share/boost 2>/dev/null || true
    fi

    # Relock the floating self-inputs to HEAD *in CI* before building. The
    # committed narHash for `github:diegonmarcos/unix` is computed on the dev
    # laptop via nix's git backend, but the runner fetches the codeload tarball
    # — and because the repo carries submodules, the two backends produce
    # DIFFERENT NAR hashes for the same rev → hard "NAR hash mismatch in input".
    # These inputs declare no ref (they float to default-branch HEAD), so
    # relocking here is semantically identical and, crucially, self-consistent:
    # the same nix that writes the lock also validates the fetch. Devs therefore
    # never need to hand-commit an (unreproducible) lock bump. CI-only guard so a
    # local ci-build stays offline-friendly.
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        log_info "Relocking floating self-inputs (unix-repo, cloud-repo) to HEAD..."
        ( cd "$SRC_DIR" && nix flake update unix-repo cloud-repo \
            --accept-flake-config --extra-experimental-features "nix-command flakes" ) \
            || log_warn "self-input relock failed — falling back to committed lock"
    fi

    log_info "Building $_attr (accept-flake-config → cached substitutes)..."
    nix build "$SRC_DIR#$_attr" --impure --accept-flake-config \
        --out-link "$_out/result" --extra-experimental-features "nix-command flakes" \
        || { log_error "ci build failed"; return 1; }

    _sys=$(readlink -f "$_out/result")
    basename "$_sys" > "$_out/activation.name"
    echo "$_sys" > "$_out/activation.path"
    log_info "Exporting closure -> zstd tarball..."
    nix-store --export $(nix-store -qR "$_sys") | zstd -T0 -15 > "$_out/hm-closure.nar.zst"
    rm -f "$_out/result"
    log_success "Done: $(du -h "$_out/hm-closure.nar.zst" | cut -f1) -> $_out/"

    # ── Stage 1: layered GHCR cache (INCREMENTAL delivery) ──────────────────
    # Additive + NON-FATAL: the nar.zst above stays the active mechanism until
    # `switch` learns to consume this. Build a layered image of the SAME
    # activation closure (one layer per store path) and skopeo-copy it to GHCR —
    # skopeo skips blobs already present in the registry, so only changed layers
    # upload. Guarded by GHCR_PUSH=1 (set by the ship workflow, which holds
    # packages:write + GITHUB_TOKEN). A failure here never fails the closure export.
    if [ "${GHCR_PUSH:-0}" = "1" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
        _img="${HM_CACHE_IMAGE:-$(hm_cache_image)}"
        log_info "building + pushing layered HM cache image -> ${_img}:latest (incremental)"
        # GHA Ubuntu runners ship /etc/containers/registries.conf as legacy v1,
        # which skopeo 1.23 refuses ("must be in v2 format"). Empty v2 config —
        # fully-qualified refs need no registries. (2026-07-09 silent-push fix.)
        local _reg="$_out/registries.conf"
        printf 'unqualified-search-registries = []\n' > "$_reg"
        if nix build "$SRC_DIR#packages.x86_64-linux.hm-cache-image" \
             --impure --accept-flake-config --out-link "$_out/hm-cache-image" \
             --extra-experimental-features "nix-command flakes"; then
            CONTAINERS_REGISTRIES_CONF="$_reg" \
            nix run --extra-experimental-features "nix-command flakes" nixpkgs#skopeo -- \
                copy --dest-creds "x:${GITHUB_TOKEN}" \
                "docker-archive:$(readlink -f "$_out/hm-cache-image")" \
                "docker://${_img}:latest" \
                && log_success "pushed layered HM cache -> ${_img}:latest" \
                || log_warn "skopeo push failed (non-fatal — nar.zst artifact still delivered)"
        else
            log_warn "hm-cache-image build failed (non-fatal — nar.zst still delivered)"
        fi
        rm -f "$_out/hm-cache-image"
    fi
}

# _oras — oras CLI: the flake package on the desktop, `nix run` on a CI runner
# that hasn't got it on PATH. One indirection so callers never branch.
_oras() {
    if command -v oras >/dev/null 2>&1; then oras "$@"
    else nix run --extra-experimental-features "nix-command flakes" nixpkgs#oras -- "$@"; fi
}

# cmd_nixcache_publish — CI: publish the CUSTOM store paths of the freshly-built
# HM closure to GHCR as PER-PATH oras blobs (the true-incremental transport,
# 2026-07-16). Reads dist-ci/activation.path (written by ci-build). Each custom
# path -> its own `nix-store --export | zstd` blob (layer title = store hash);
# the toplevel activation name rides a manifest annotation. Content-addressed
# blobs dedup across builds (push delta); the desktop pulls only the blobs it
# LACKS (pull delta). Custom paths are emitted in TOPOLOGICAL order (tsort) so
# the desktop's per-path `nix-store --import` always has each path's references
# already valid. All logic here (engine), never inline in the workflow YAML.
cmd_nixcache_publish() {
    log_header "CI: publish per-path GHCR nix cache (oras)"
    [ -n "${GITHUB_TOKEN:-}" ] || { log_error "GITHUB_TOKEN required"; return 1; }
    command -v jq >/dev/null 2>&1 || { log_error "jq required"; return 1; }
    _cfg="$NIX_CACHE_CFG"
    [ "$(jq -r '.enabled' "$_cfg" 2>/dev/null)" = "true" ] || { log_warn "nix cache disabled"; return 0; }
    _ref="$(jq -r '.oci_ref' "$_cfg")"; _tag="$(jq -r '.oci_tag' "$_cfg")"
    _mtype="$(jq -r '.blob_media_type' "$_cfg")"; _tlann="$(jq -r '.toplevel_annotation' "$_cfg")"
    _manf="$(jq -r '.manifest_file' "$_cfg")"
    _out="$SCRIPT_DIR/dist-ci"
    _top="$(cat "$_out/activation.path" 2>/dev/null)"
    [ -n "$_top" ] && [ -d "$_top" ] || { log_error "no dist-ci/activation.path — run ci-build first"; return 1; }
    _tlname="$(basename "$_top")"; log_info "toplevel: $_tlname"

    # 1) topological order of the whole closure (deps BEFORE dependents) — the
    #    order a per-path `nix-store --import` can consume safely.
    _work="$_out/nixcache"; rm -rf "$_work"; mkdir -p "$_work/blobs"
    for p in $(nix-store -qR "$_top"); do
        for r in $(nix-store -q --references "$p"); do
            [ "$r" = "$p" ] || printf '%s %s\n' "$r" "$p"
        done
        printf '%s %s\n' "$p" "$p"   # keep leaves (no refs) in the graph
    done | tsort > "$_work/topo.txt"

    # 2) custom = closure MINUS what cache.nixos.org serves (robust retry probe;
    #    only a real 200 = public, --retry so a transient blip never masquerades
    #    as custom). Keep custom paths IN TOPOLOGICAL ORDER.
    nix-store -qR "$_top" | sort > "$_work/all.txt"
    log_info "probing cache.nixos.org for $(wc -l < "$_work/all.txt") paths..."
    xargs -a "$_work/all.txt" -P 16 -I{} sh -c '
        h=$(basename "{}"); h=${h%%-*}
        curl -s -f -o /dev/null --retry 6 --retry-connrefused --retry-delay 1 \
          --max-time 40 "https://cache.nixos.org/${h}.narinfo" && echo "{}"
    ' | sort > "$_work/public.txt" || true
    comm -23 "$_work/all.txt" "$_work/public.txt" | sort > "$_work/custom-set.txt"
    grep -Fx -f "$_work/custom-set.txt" "$_work/topo.txt" > "$_work/$_manf"   # topo-ordered custom
    _n=$(wc -l < "$_work/$_manf")
    log_info "custom paths: $_n of $(wc -l < "$_work/all.txt") (rest from cache.nixos.org)"
    [ "$_n" -gt 0 ] || { log_warn "no custom paths — nothing to publish"; return 0; }

    # 3) export each custom path to its own zstd blob (filename = store hash).
    while IFS= read -r p; do
        h=$(basename "$p"); h=${h%%-*}
        nix-store --export "$p" | zstd -T0 -19 -q -o "$_work/blobs/$h.zst"
    done < "$_work/$_manf"
    cp "$_work/$_manf" "$_work/blobs/$_manf"
    # Also ship the PUBLIC-deps list so the desktop can pre-substitute every
    # cache.nixos.org path BEFORE importing customs — then the topo-ordered
    # import has ALL refs valid in one pass (no fragile per-error recovery).
    cp "$_work/public.txt" "$_work/blobs/public.txt" 2>/dev/null || : > "$_work/blobs/public.txt"
    log_info "exported $_n blobs, $(du -sh "$_work/blobs" | cut -f1) — pushing ${_ref}:${_tag}"

    # 4) oras push — one layer per blob (title = <hash>.zst, IN topo order),
    #    toplevel on a manifest annotation. Content-addressed → GHCR dedups
    #    unchanged blobs, so only changed paths actually upload.
    _files=""
    while IFS= read -r p; do
        h=$(basename "$p"); h=${h%%-*}; _files="$_files $h.zst:$_mtype"
    done < "$_work/$_manf"
    ( cd "$_work/blobs" && _oras push --disable-path-validation \
        --username x --password "${GITHUB_TOKEN}" \
        --annotation "${_tlann}=${_tlname}" \
        "${_ref}:${_tag}" $_files "$_manf:text/plain" "public.txt:text/plain" ) \
      && log_success "published ${_n}-path nix cache -> ${_ref}:${_tag}" \
      || { log_error "oras push failed"; return 1; }
    rm -rf "$_work"
}

# ghcr_pull_layered <image:tag> — try to materialise a layered GHCR closure
# image's /nix/store paths onto the real local store, skipping any path
# already present (genuine incremental — unchanged layers are never even
# pulled by `docker pull`, and unchanged store paths are never re-copied
# locally either). Returns 1 (silently, caller falls back) on ANY failure:
# docker missing, image missing, pull failure — additive, never fatal.
# Populated by `hm-cache-image` (src/flake.nix) + the skopeo push in
# cmd_ci_build below.
ghcr_pull_layered() {
    _img="$1"
    command -v docker >/dev/null 2>&1 || return 1
    log_info "Trying layered GHCR pull: $_img ..."
    docker pull "$_img" >/dev/null 2>&1 || { log_warn "GHCR image unavailable — falling back to nar.zst"; return 1; }

    _tmp="hm-cache-extract-$$"
    docker create --name "$_tmp" "$_img" >/dev/null 2>&1 || { log_warn "docker create failed — falling back to nar.zst"; return 1; }

    _sudo="/run/wrappers/bin/sudo"; [ -x "$_sudo" ] || _sudo="sudo"
    _copied=0; _skipped=0
    # buildLayeredImage roots the closure at /nix/store inside the image —
    # list it via a throwaway inspect run, then `docker cp` only the
    # missing store paths (same skip-if-present idiom as the VM's
    # activate.sh in b_infra/_shared/vm-pilot/src/Dockerfile.transport).
    for _p in $(docker run --rm "$_img" sh -c 'ls /nix/store' 2>/dev/null); do
        _host="/nix/store/$_p"
        if [ -e "$_host" ]; then
            _skipped=$((_skipped + 1))
            continue
        fi
        if $_sudo sh -c "docker cp '$_tmp:/nix/store/$_p' - 2>/dev/null | tar -x -C /nix/store" 2>/dev/null && [ -e "$_host" ]; then
            _copied=$((_copied + 1))
        fi
    done
    docker rm "$_tmp" >/dev/null 2>&1 || true
    log_success "Layered pull: $_copied copied, $_skipped already present"
    [ "$_copied" -gt 0 ] || [ "$_skipped" -gt 0 ]
}

# pull [artifact-dir] — run on the Surface. Import a GHA-built home-manager
# closure and run its activate script. NO eval, NO build -> cannot freeze.
# Default dir dist-ci/ (e.g. after: gh run download -n nixos-desktop-hm-closure -D dist-ci).
cmd_pull() {
    log_header "Activate prebuilt home-manager closure (no eval — cannot freeze)"
    check_nix || return 1
    _art="${1:-$SCRIPT_DIR/dist-ci}"
    _tb="$_art/hm-closure.nar.zst"

    # KDE progress popup (verbosity + progress bar + Cancel) for the PULL path —
    # the SAME wrapper the local-eval switch uses. Transparent passthrough when
    # the wrapper is absent or the session is non-graphical (SSH/CI: exec "$@").
    _nsp=""; command -v nix-switch-progress-wrap >/dev/null 2>&1 && _nsp="nix-switch-progress-wrap"
    export NSP_SRC_DIR="$SRC_DIR"

    _sys=""
    if [ -f "$_art/activation.name" ]; then
        _sys="/nix/store/$(cat "$_art/activation.name")"
    fi

    # ── Try GHCR-layered pull first (incremental) ────────────────────────
    _img="${HM_CACHE_IMAGE:-$(hm_cache_image)}:latest"
    if [ -n "$_sys" ] && [ -d "$_sys" ]; then
        log_info "$_sys already present locally — skipping pull entirely."
    elif ghcr_pull_layered "$_img" && [ -n "$_sys" ] && [ -d "$_sys" ]; then
        log_success "Activation closure materialised via layered GHCR pull."
    else
        [ -f "$_tb" ] || { log_error "no closure tarball at $_tb (fetch: gh run download -n nixos-desktop-hm-closure -D '$_art')"; return 1; }
        [ -f "$_art/activation.name" ] || { log_error "missing $_art/activation.name"; return 1; }
        _sys="/nix/store/$(cat "$_art/activation.name")"

        _sudo="/run/wrappers/bin/sudo"; [ -x "$_sudo" ] || _sudo="sudo"
        log_info "Importing closure into the store (no build)..."
        zstd -d -c "$_tb" | $_nsp $_sudo nix-store --import >/dev/null || { log_error "import failed"; return 1; }
    fi
    [ -d "$_sys" ] || { log_error "imported path $_sys missing after import"; return 1; }

    # home-manager activationPackages expose the activator at ./activate. Run it
    # as the USER (it writes ~/.config etc) — NOT under sudo.
    _act="$_sys/activate"
    [ -x "$_act" ] || { log_error "no activate script in $_sys"; return 1; }

    # Auto-medicine: the prebuilt activate has no `-b backup` (that's a switch-time
    # flag), so it aborts when a regular file is "in the way of" an HM symlink
    # (e.g. ~/.gtkrc-2.0). Same idiom as the termux engine: on that failure, back
    # up the in-the-way files (flake always wins) and retry once. Idempotent —
    # only triggers on this exact message.
    export NSP_FLAKE_ATTR="$_sys"   # closure-size panel reads this store path
    # Let home-manager's own checkLinkTargets back up in-the-way regular files
    # NATIVELY (moves each to "<file>.$HOME_MANAGER_BACKUP_EXT") in a SINGLE pass
    # — the prebuilt `activate` honours this env var. A unique per-run timestamp
    # extension avoids the "backup would be clobbered" re-collision on repeated
    # runs. This is the robust mechanism; the grep/mv retry below is now only a
    # belt-and-suspenders fallback (its rc came from the popup wrapper, not the
    # activator, so it could silently skip — the env var removes that fragility).
    export HOME_MANAGER_BACKUP_EXT="hm-bak-$(date +%Y%m%d-%H%M%S)"
    log_info "Activating ($_act)  [backup-ext: $HOME_MANAGER_BACKUP_EXT]..."
    _alog=$(mktemp)
    # Wrap the activation in the KDE popup (phases + progress + Cancel). The
    # wrapper tees full output to NSP_LOG_FILE so the "in the way" retry below
    # still works; non-graphical falls back to a plain capture.
    if [ -n "$_nsp" ]; then NSP_LOG_FILE="$_alog" $_nsp "$_act" >/dev/null 2>&1; _rc=$?; else "$_act" >"$_alog" 2>&1; _rc=$?; fi
    cat "$_alog"
    if [ "$_rc" -ne 0 ] && grep -q "is in the way of" "$_alog"; then
        log_warn "home-manager file conflict — backing up in-the-way files and retrying"
        _ts=$(date +%Y%m%d-%H%M%S)
        grep "is in the way of" "$_alog" | sed -n "s/.*Existing file '\([^']*\)' is in the way.*/\1/p" | while IFS= read -r _p; do
            if [ -e "$_p" ] && [ ! -L "$_p" ]; then
                mv -f "$_p" "${_p}.hm-backup-${_ts}" && log_info "  backed up: $_p -> ${_p}.hm-backup-${_ts}"
            fi
        done
        if [ -n "$_nsp" ]; then NSP_LOG_FILE="$_alog" $_nsp "$_act" >/dev/null 2>&1; _rc=$?; else "$_act" >"$_alog" 2>&1; _rc=$?; fi
        cat "$_alog"
    fi
    rm -f "$_alog"
    [ "$_rc" -eq 0 ] || { log_error "home-manager activation failed (rc=$_rc)"; return 1; }
    log_success "Activated prebuilt home-manager generation (no eval)."
}

# ghcr_incremental_switch <artifact-dir> — switch using ONLY the layered GHCR
# cache image: NO ~6GB artifact download. A KB-sized `skopeo inspect` reads the
# activation store path from the image's OCI label (com.diegonmarcos.activation
# -path), then ghcr_pull_layered materialises only the store paths not already
# present locally (docker pull skips unchanged layers; docker cp skips present
# paths) — so a typical update transfers only the changed layers (MBs). Writes
# activation.name into the artifact dir so cmd_pull activates without any
# download. Returns 0 iff the activation path is fully present afterwards; 1 on
# ANY failure (no skopeo, no gh auth, unlabeled image, image/pull failure) so
# the caller falls back to the byte-exact artifact-download path.
# nixcache_switch <artifact-dir> — THE incremental transport (2026-07-11, was
# gh-pages until git rejected the large nar push; now a GitHub RELEASE asset).
# Pulls the new HM generation by downloading ONE small tarball (custom store
# paths only = tens of MB, closure minus cache.nixos.org) from a rolling Release
# tag, extracting it, and streaming those paths into /nix/store — no 6GB
# artifact, no 14G staging, works on a full disk, cannot freeze. Verified
# primitive: `nix copy --from file://` works for the non-root user with
# --no-check-sigs (no trusted-user / system change). Flow: toplevel from the
# GHCR label (KB skopeo inspect) → download+extract the delta cache asset →
# `nix copy --from file://<dir>` the CUSTOM paths → let cache.nixos.org fill the
# public ones → write activation.name for cmd_pull. Returns 1 (caller falls
# back to the full artifact) on any miss (release not published yet, offline…).
# _oras … — run oras from the desktop env if present, else via nix run (the
# flake ships oras, but nix run keeps the switch working before activation).
_oras() {
    if command -v oras >/dev/null 2>&1; then oras "$@"
    else nix run --extra-experimental-features "nix-command flakes" nixpkgs#oras -- "$@"; fi
}
# _closure_valid <storepath> — true iff the path AND its whole closure are valid
# in the store. nix-store has NO `--check-validity --recursive` flag (it errors
# 'unknown flag'), so the old check ALWAYS failed. Correct primitive: `-qR`
# lists the closure from the db (succeeds only if the top path is valid), then
# `--check-validity --print-invalid` reports any missing member; empty = valid.
_closure_valid() {
    nix-store -qR "$1" >/dev/null 2>&1 || return 1
    [ -z "$(nix-store -qR "$1" 2>/dev/null | xargs -r nix-store --check-validity --print-invalid 2>/dev/null)" ]
}
nixcache_switch() {
    _art="$1"
    command -v jq >/dev/null 2>&1 && [ -f "$NIX_CACHE_CFG" ] || return 1
    [ "$(jq -r '.enabled' "$NIX_CACHE_CFG" 2>/dev/null)" = "true" ] || return 1
    command -v gh >/dev/null 2>&1 && command -v zstd >/dev/null 2>&1 || return 1
    _ref="$(jq -r '.oci_ref' "$NIX_CACHE_CFG")"
    _tag="$(jq -r '.oci_tag' "$NIX_CACHE_CFG")"
    _ann="$(jq -r '.toplevel_annotation' "$NIX_CACHE_CFG")"
    _tok="$(gh auth token 2>/dev/null)" || return 1
    # GHCR login: username must be the package OWNER (derived from oci_ref —
    # data-driven), NOT a dummy "x" (that authed as anonymous → 401 on the
    # private package → silent empty fetches). Show the result (verbose).
    _owner="$(printf '%s' "$_ref" | cut -d/ -f2)"
    log_info "nixcache: oras login ghcr.io as '$_owner' ..."
    printf '%s' "$_tok" | _oras login ghcr.io -u "$_owner" --password-stdin 2>&1 \
        | sed 's/^/  [login] /' \
        || { log_warn "nixcache: oras login failed — falling back."; return 1; }

    log_info "nixcache: fetching OCI manifest $_ref:$_tag ..."
    mkdir -p "$_art"; _man="$_art/nixcache-manifest.json"
    _oras manifest fetch "$_ref:$_tag" > "$_man" 2>"$_art/nixcache-manifest.err" \
        || { log_warn "nixcache: manifest unreachable ($(tail -1 "$_art/nixcache-manifest.err" 2>/dev/null)) — falling back."; return 1; }
    _sysname="$(jq -r --arg k "$_ann" '.annotations[$k] // empty' "$_man")"
    [ -n "$_sysname" ] || { log_warn "nixcache: no toplevel annotation on manifest — falling back."; return 1; }
    _sys="/nix/store/$_sysname"
    basename "$_sys" > "$_art/activation.name"
    # VALIDITY, not dir-existence: a prior partial import can leave the gen DIR
    # present while its deps (home-manager-path/files) are invalid → activate
    # dies instantly. --check-validity --recursive verifies the WHOLE closure.
    if _closure_valid "$_sys"; then
        log_success "nixcache: $_sysname closure already fully valid — no pull."; return 0
    fi

    # ── THE robust layered pull (2026-07-17): no fragile per-error recovery.
    # (0) pull two tiny index blobs: public.txt (all cache.nixos.org deps) and
    #     the topo-ordered custom path list ($_manf). (A) pre-substitute EVERY
    #     public dep from cache.nixos.org — so every custom path's public refs
    #     are valid. (B) fetch blobs for custom paths this box lacks/corrupts.
    #     (C) import customs IN TOPOLOGICAL ORDER — one pass, every ref already
    #     valid, nothing to deadlock. Nix (not us) owns dependency resolution.
    _bd="$_art/nixcache-blobs"; rm -rf "$_bd"; mkdir -p "$_bd"
    _tab="$(printf '\t')"; _manf="$(jq -r '.manifest_file' "$NIX_CACHE_CFG")"
    _lst="$_art/nixcache-layers.tsv"
    jq -r '.layers[] | "\(.digest)\t\(.annotations["org.opencontainers.image.title"])"' "$_man" > "$_lst"
    _dig() { awk -F"$_tab" -v t="$1" '$2==t{print $1; exit}' "$_lst"; }
    _pd="$(_dig public.txt)"; _md="$(_dig "$_manf")"
    [ -n "$_pd" ] && _oras blob fetch "${_ref}@${_pd}" --output "$_art/public.txt" >/dev/null 2>&1
    [ -n "$_md" ] && _oras blob fetch "${_ref}@${_md}" --output "$_art/custom-topo.txt" >/dev/null 2>&1
    if [ ! -s "$_art/custom-topo.txt" ] || [ ! -f "$_art/public.txt" ]; then
        log_warn "nixcache: cache predates the public/topo index (needs a CI re-publish) — falling back."; return 1
    fi

    # (A) pre-substitute all public deps (nix fetches only the ones we lack).
    log_info "nixcache: pre-substituting $(wc -l < "$_art/public.txt") public deps from cache.nixos.org (only missing fetch) ..."
    xargs -a "$_art/public.txt" -r nix copy --from https://cache.nixos.org --no-check-sigs 2>&1 | tail -2

    # (B) which custom paths must we fetch? missing dirs + present-but-INVALID
    #     (a killed run can leave corrupt dirs). One batched validity check.
    : > "$_art/present.txt"; : > "$_art/tofetch.txt"
    while IFS= read -r _p; do
        _ph="$(basename "$_p")"; _hp="$(ls -d /nix/store/${_ph%%-*}-* 2>/dev/null | head -1)"
        if [ -n "$_hp" ]; then echo "$_hp" >> "$_art/present.txt"; else echo "$_p" >> "$_art/tofetch.txt"; fi
    done < "$_art/custom-topo.txt"
    [ -s "$_art/present.txt" ] && xargs -a "$_art/present.txt" -r nix-store --check-validity --print-invalid 2>/dev/null >> "$_art/tofetch.txt"
    sort -u "$_art/tofetch.txt" -o "$_art/tofetch.txt"
    _nf=$(wc -l < "$_art/tofetch.txt")
    log_info "nixcache: fetching $_nf custom blobs (missing/corrupt) of $(wc -l < "$_art/custom-topo.txt") ..."
    _i=0
    while IFS= read -r _p; do
        _i=$((_i+1)); _ph="$(basename "$_p")"; h="${_ph%%-*}"
        _d="$(_dig "${h}.zst")"; [ -n "$_d" ] || _d="$(_dig "blobs/${h}.zst")"
        [ -n "$_d" ] || { log_warn "  [$_i/$_nf] no blob for $h"; continue; }
        log "  [$_i/$_nf] FETCH $_ph"
        _oras blob fetch "${_ref}@${_d}" --output "$_bd/${h}.zst" >/dev/null 2>&1 || log_warn "  fetch failed: $h"
    done < "$_art/tofetch.txt"

    # (C) import in TOPOLOGICAL order — deps first, public already present.
    log_info "nixcache: importing custom paths in topological order ..."
    while IFS= read -r _p; do
        _ph="$(basename "$_p")"; h="${_ph%%-*}"; f="$_bd/${h}.zst"
        [ -e "$f" ] || continue
        if zstd -dq -c "$f" | /run/wrappers/bin/sudo nix-store --import >/dev/null 2>"$f.err"; then
            log "  imported $_ph"
        else
            log_warn "  import failed $_ph: $(tail -1 "$f.err" 2>/dev/null)"
        fi
        rm -f "$f" "$f.err"
    done < "$_art/custom-topo.txt"

    if _closure_valid "$_sys"; then
        rm -rf "$_bd"
        log_success "nixcache: closure fully valid (GHCR layered delta — NO 6GB; pre-filled public + topo import)."
        return 0
    fi
    log_warn "nixcache: $_sys still missing after import — falling back."
    return 1
}

ghcr_incremental_switch() {
    _art="$1"
    # The docker-layered incremental transport is BROKEN (buildLayeredImage has no
    # shell → `docker run sh` fails, copies 0 paths; OCI layers carry no nix-DB
    # metadata → can't register/activate). Data-driven kill switch: when
    # .safety.incremental_pull is false, skip it entirely so the reliable nar.zst
    # artifact path (nix-store --import, proper DB registration) runs. See the
    # _incremental_comment in hm-auto-update.json.
    # NB: read WITHOUT jq's `//` operator — `false // true` evaluates to `true`
    # in jq (false is treated as empty), which would silently defeat this switch.
    _inc="$(jq -r '.safety.incremental_pull' "$HM_AUTO_CFG" 2>/dev/null)"
    if [ "$_inc" = "false" ]; then
        log_info "Incremental docker pull disabled (broken transport) — using the reliable nar.zst artifact path."
        return 1
    fi
    command -v skopeo >/dev/null 2>&1 || { log_warn "skopeo not found — cannot do label-based incremental switch, falling back to artifact download."; return 1; }
    command -v gh >/dev/null 2>&1 || return 1
    _img="${HM_CACHE_IMAGE:-$(hm_cache_image)}:latest"
    _label="$(hm_cache_label)"
    _tok="$(gh auth token 2>/dev/null)" || { log_warn "gh not authenticated — falling back to artifact download."; return 1; }
    log_info "Inspecting $_img for activation path (label $_label)..."
    _sys="$(skopeo inspect --creds "x:$_tok" --format "{{ index .Labels \"$_label\" }}" "docker://$_img" 2>/dev/null)"
    if [ -z "$_sys" ] || [ "$_sys" = "<no value>" ]; then
        log_warn "cache image carries no '$_label' label (predates labeled builds) — falling back to artifact download."
        return 1
    fi
    log_info "Target activation: $_sys"
    mkdir -p "$_art"
    basename "$_sys" > "$_art/activation.name"
    if [ -d "$_sys" ]; then
        log_success "activation path already present locally — incremental switch needs no pull."
        return 0
    fi
    if ghcr_pull_layered "$_img" && [ -d "$_sys" ]; then
        log_success "activation path materialised via layered GHCR pull (incremental — NO artifact download)."
        return 0
    fi
    log_warn "layered pull incomplete ($_sys still missing) — falling back to artifact download."
    return 1
}

# switch runner (DEFAULT) — one-shot: fetch the latest GHA-built home-manager
# closure + activate it locally. No local eval → cannot freeze the 8GB Surface.
# Incremental-first: tries ghcr_incremental_switch (layered GHCR cache, only
# changed layers, no big download); falls back to the full artifact download
# only when that path is unavailable. Assumes the ship workflow already ran for
# your pushed HEAD (GHA builds on push), so `switch local` is the escape hatch
# to eval on-device. Artifact name overridable via HM_CLOSURE_ARTIFACT;
# workflow (hint only) via HM_SHIP_WORKFLOW.
cmd_switch_runner() {
    log_header "switch (runner): fetch GHA-built closure + activate (no local eval)"
    # DELTA-ONLY by default (2026-07-17, user directive: the layered cache MUST
    # work; no silent 6GB fallback masking delta bugs). The full-artifact pull is
    # now an EXPLICIT opt-in on its own argv:  ./build.sh switch full
    _full=0
    if [ "${1:-}" = "full" ]; then _full=1; shift; fi
    _host="${1:-surface-plasma}"; _user="${2:-diego}"
    command -v gh >/dev/null 2>&1 || { log_error "gh CLI not found — install it, or use: ./build.sh switch local"; return 1; }
    # CONCURRENCY LOCK (root-caused 2026-07-08): multiple sessions invoking
    # `switch` concurrently each `rm -rf dist-ci` and restart the ~6GB
    # download, clobbering the other's partial zip — none ever completes.
    # flock on fd 9: second caller fails fast instead of silently destroying
    # the first one's progress. Lock dir survives; the fd releases on exit.
    _lock="$SCRIPT_DIR/.switch.lock"
    exec 9>"$_lock"
    if ! flock -n 9; then
        log_error "another 'build.sh switch' is already running (lock: $_lock)."
        log_error "wait for it to finish — concurrent switches clobber each other's download."
        return 1
    fi
    _artname="${HM_CLOSURE_ARTIFACT:-nixos-desktop-hm-closure}"
    _wf="${HM_SHIP_WORKFLOW:-ship_nix-flakes_desktop_hm.yaml}"
    _art="$SCRIPT_DIR/dist-ci"
    rm -rf "$_art"; mkdir -p "$_art"

    # ── THE cache: GHCR per-path OCI delta (streams only the paths this box
    #    lacks — no 6GB, no 14G staging). This is the CONTRACT. On failure we do
    #    NOT silently download 6GB (that masks delta bugs — user directive
    #    2026-07-17). Fail LOUDLY so the real error is visible and gets fixed.
    if nixcache_switch "$_art"; then
        cmd_pull "$_art"
        return $?
    fi

    if [ "$_full" = 0 ]; then
        log_error "════════════════════════════════════════════════════════════════"
        log_error "DELTA (GHCR per-path) SWITCH FAILED — see the nixcache error above."
        log_error "NOT falling back to the 6GB artifact: the layered cache is the contract."
        log_error "To force the full-artifact pull explicitly:   ./build.sh switch full"
        log_error "════════════════════════════════════════════════════════════════"
        return 1
    fi

    log_warn "'full' requested — pulling the entire ~6GB artifact (explicit opt-in)."
    rm -rf "$_art"; mkdir -p "$_art"

    # Resolve SUCCESSFUL runs of the HM ship workflow and pull the artifact by
    # run-id — `gh run download -n <name>` with NO run-id only checks the single
    # most-recent run, which may be a newer/failed one lacking the artifact.
    # GHA expires artifacts (retention window), so the LATEST successful run may
    # have no artifact even while an older successful run still does — walk the
    # recent successful runs newest-first until one downloads.
    log_info "Resolving recent successful '$_wf' runs..."
    _runids="$(gh run list --workflow "$_wf" --status success --limit 10 --json databaseId --jq '.[].databaseId' 2>/dev/null)"
    if [ -z "$_runids" ]; then
        log_error "no successful '$_wf' run found on GitHub."
        log_error "GHA builds on push — commit+push first (or: gh workflow run $_wf),"
        log_error "then re-run:  ./build.sh switch      (on-device eval instead: ./build.sh switch local)"
        return 1
    fi
    # Walk successful runs newest-first. Distinguish a genuinely EXPIRED artifact
    # (fall through to an older run) from a LOCAL failure — no space or OOM kill —
    # which every run would hit identically, so we fail fast with the real cause
    # instead of thrashing 6 GB downloads into a full disk (root cause of the
    # "missing/expired" mislabel). The closure zip is ~6 GB and gh unzips it in
    # place, so we require ~2.2× its size free before attempting.
    _runid=""
    for _rid in $_runids; do
        # Query this run's artifact metadata: expired flag + compressed size.
        _meta="$(gh api "repos/{owner}/{repo}/actions/runs/$_rid/artifacts" \
            --jq ".artifacts[] | select(.name==\"$_artname\") | \"\(.expired) \(.size_in_bytes)\"" 2>/dev/null | head -1)"
        if [ -z "$_meta" ]; then
            log_warn "run $_rid has no '$_artname' artifact — trying older run..."; continue
        fi
        _expired="${_meta%% *}"; _size="${_meta##* }"
        if [ "$_expired" = "true" ]; then
            log_warn "artifact on run $_rid is expired — trying older run..."; continue
        fi
        # Disk precheck (KB): `gh run download` first stages the artifact ZIP in
        # $TMPDIR, then extracts hm-closure.nar.zst into -D and deletes the zip.
        # ROOT-CAUSE 2026-07-08: default TMPDIR=/tmp is tmpfs (impermanent root)
        # — a ~6GB zip staged there consumes RAM 1:1 and the freeze-guard/OOM
        # kills the download every time ("network drop" was a misdiagnosis).
        # Fix: TMPDIR is pointed at the disk-backed artifact dir below, so the
        # transient peak is zip + extracted file on DISK: ~2× artifact size,
        # plus import delta headroom → 2.3×.
        _need_kb=$(( _size / 1024 * 23 / 10 ))
        _free_kb="$(df -Pk "$SCRIPT_DIR" | awk 'END{print $4}')"
        if [ "$_free_kb" -lt "$_need_kb" ]; then
            log_error "not enough disk for the closure: need ~$(( _need_kb/1024/1024 ))G free, have $(( _free_kb/1024/1024 ))G on $(df -Ph "$SCRIPT_DIR" | awk 'END{print $6}')."
            log_error "free space (nix-collect-garbage -d / docker system prune / clear caches) then retry — older runs are the same size, not retrying."
            return 1
        fi
        log_info "Downloading '$_artname' (~$(( _size/1024/1024 ))MB) from run $_rid..."
        rm -rf "$_art"; mkdir -p "$_art"
        # TMPDIR on DISK (not tmpfs): gh stages the artifact zip in TMPDIR
        # before extracting — see the root-cause note on the precheck above.
        if TMPDIR="$_art" gh run download "$_rid" -n "$_artname" -D "$_art" 2>/dev/null; then
            _runid="$_rid"; break
        fi
        log_error "download failed for run $_rid despite live artifact + adequate disk —"
        log_error "likely a network drop. Not retrying older runs (same failure)."
        return 1
    done
    if [ -z "$_runid" ]; then
        log_error "no live '$_artname' artifact in the last 10 successful runs (all expired/missing)."
        log_error "re-run the build:  gh workflow run $_wf   then retry  ./build.sh switch"
        return 1
    fi
    cmd_pull "$_art"
}

# ============================================================================
# TUI MENU
# ============================================================================

print_banner() {
    clear
    printf "${CYAN}"
    cat << 'EOF'
    ____  _                      ____
   / __ \(_)__  ____ _____      / __ \___ _   __
  / / / / / _ \/ __ `/ __ \    / / / / _ \ | / /
 / /_/ / /  __/ /_/ / /_/ /   / /_/ /  __/ |/ /
/_____/_/\___/\__, /\____/   /_____/\___/|___/
             /____/
    Portable Development Environment
EOF
    printf "${NC}\n"
    printf "  ${WHITE}Version: 1.0.0${NC}\n"
    printf "  ${WHITE}Config:  build.json${NC}\n\n"
}

print_menu() {
    printf "${BOLD}${WHITE}=== MAIN MENU ===${NC}\n\n"

    printf "${YELLOW}Nix Operations:${NC}\n"
    printf "  ${GREEN}1)${NC} Install Nix          - Fresh Nix installation\n"
    printf "  ${GREEN}2)${NC} Switch Config        - Apply Home Manager config\n"
    printf "  ${GREEN}3)${NC} Update Flake         - Update flake inputs\n"
    printf "  ${GREEN}4)${NC} Show Flake           - Display flake outputs\n"
    printf "  ${GREEN}5)${NC} Dev Shell            - Enter nix develop shell\n"
    printf "\n"

    printf "${YELLOW}Container Operations:${NC}\n"
    printf "  ${GREEN}6)${NC} Build Image          - Build Nix container image\n"
    printf "  ${GREEN}7)${NC} Load Image           - Load image into runtime\n"
    printf "  ${GREEN}8)${NC} Run Container        - Start interactive container\n"
    printf "  ${GREEN}9)${NC} Push Image           - Push to registry\n"
    printf "\n"

    printf "${YELLOW}Compose Operations:${NC}\n"
    printf "  ${GREEN}10)${NC} Compose Up          - Start compose services\n"
    printf "  ${GREEN}11)${NC} Compose Down        - Stop compose services\n"
    printf "  ${GREEN}12)${NC} Compose Shell       - Enter compose container\n"
    printf "\n"

    printf "${YELLOW}Distrobox Operations:${NC}\n"
    printf "  ${GREEN}13)${NC} Create Distrobox    - Create new distrobox\n"
    printf "  ${GREEN}14)${NC} Enter Distrobox     - Enter distrobox shell\n"
    printf "  ${GREEN}15)${NC} Remove Distrobox    - Remove distrobox\n"
    printf "\n"

    printf "${YELLOW}Utilities:${NC}\n"
    printf "  ${GREEN}16)${NC} Status              - Show system status\n"
    printf "  ${GREEN}17)${NC} Clean               - Clean build artifacts\n"
    printf "  ${GREEN}18)${NC} View Log            - View build log\n"
    printf "  ${GREEN}19)${NC} Clear Log           - Clear build log\n"
    printf "\n"

    printf "  ${RED}q)${NC}  Quit\n"
    printf "\n"
}

read_choice() {
    printf "${BOLD}Enter choice: ${NC}" >&2
    read -r choice
    printf "%s" "$choice"
}

prompt_host() {
    printf "\n${YELLOW}Available hosts:${NC}\n" >&2
    printf "  1) surface  - Full development (default)\n" >&2
    printf "  2) server   - Server/cloud ops\n" >&2
    printf "  3) cli      - CLI-only\n" >&2
    printf "  4) minimal  - Base development\n" >&2
    printf "\n${BOLD}Select host [1]: ${NC}" >&2
    read -r host_choice

    case "$host_choice" in
        2) printf "server" ;;
        3) printf "cli" ;;
        4) printf "minimal" ;;
        *) printf "surface" ;;
    esac
}

prompt_image_type() {
    printf "\n${YELLOW}Image type:${NC}\n" >&2
    printf "  1) full    - All CLI tools (default)\n" >&2
    printf "  2) minimal - Shell + core only\n" >&2
    printf "\n${BOLD}Select type [1]: ${NC}" >&2
    read -r type_choice

    case "$type_choice" in
        2) printf "minimal" ;;
        *) printf "full" ;;
    esac
}

pause() {
    printf "\n${YELLOW}Press Enter to continue...${NC}"
    read -r _
}

run_tui() {
    while true; do
        print_banner
        print_menu
        choice=$(read_choice)

        case "$choice" in
            1) nix_install; pause ;;
            2) host=$(prompt_host); nix_switch "$host"; pause ;;
            3) nix_update; pause ;;
            4) nix_show; pause ;;
            5) nix_develop ;;
            6) img_type=$(prompt_image_type); container_build "$img_type"; pause ;;
            7) container_load; pause ;;
            8) img_type=$(prompt_image_type); container_run "$img_type" ;;
            9)
                printf "\n${BOLD}Registry (e.g., ghcr.io/username): ${NC}"
                read -r registry
                container_push "$registry"
                pause
                ;;
            10) compose_up; pause ;;
            11) compose_down; pause ;;
            12) compose_shell ;;
            13)
                printf "\n${BOLD}Box name [diego-dev]: ${NC}"
                read -r box_name
                distrobox_create "${box_name:-diego-dev}"
                pause
                ;;
            14)
                printf "\n${BOLD}Box name [diego-dev]: ${NC}"
                read -r box_name
                distrobox_enter "${box_name:-diego-dev}"
                ;;
            15)
                printf "\n${BOLD}Box name [diego-dev]: ${NC}"
                read -r box_name
                distrobox_remove "${box_name:-diego-dev}"
                pause
                ;;
            16) status; pause ;;
            17) clean; pause ;;
            18) view_log ;;
            19) clear_log; pause ;;
            q|Q)
                printf "\n${GREEN}Goodbye!${NC}\n"
                exit 0
                ;;
            *)
                log_warn "Invalid choice: $choice"
                pause
                ;;
        esac
    done
}

# ============================================================================
# CLI HELP
# ============================================================================

show_help() {
    cat << EOF
${BOLD}Diego's Dev Environment - Build Script${NC}

${YELLOW}USAGE:${NC}
    ./build.sh              Show this help
    ./build.sh <command>    Run specific command
    ./build.sh tui          Launch interactive TUI menu

${YELLOW}NIX COMMANDS:${NC}
    install                 Install Nix package manager
    switch [runner|local]   Apply Home Manager config. DEFAULT=runner: fetch the
                            latest GHA-built closure + activate (no local eval, cannot freeze).
                            'switch local [host] [user]' = eval+build+activate on-device (heavy).
    build [profile]         Dry build — evaluate flake without activating (verify-only)
    ci-build [profile]      [GHA x86] Build + export the closure tarball -> dist-ci/
    pull [dir]              Import a GHA-built closure + activate (NO eval — never freezes)
    update                  Update flake inputs
    show                    Show flake outputs
    develop                 Enter nix develop shell

${YELLOW}CONTAINER COMMANDS:${NC}
    container-build [type]  Build OCI image (full|minimal)
    container-load          Load image into runtime
    container-run [type]    Run interactive container
    container-push <reg>    Push to registry

${YELLOW}COMPOSE COMMANDS:${NC}
    compose-up              Start compose services
    compose-down            Stop compose services
    compose-shell           Enter compose container

${YELLOW}DISTROBOX COMMANDS:${NC}
    distrobox-create [name] Create distrobox (default: diego-dev)
    distrobox-enter [name]  Enter distrobox
    distrobox-remove [name] Remove distrobox

${YELLOW}UTILITY COMMANDS:${NC}
    tui|menu                Launch interactive TUI menu
    status                  Show system status
    clean                   Clean build artifacts
    log                     View build log
    clear-log               Clear build log

${YELLOW}HOSTS:${NC}
    surface                 Full development (all profiles + Plasma)
    server                  Server/cloud ops
    cli                     CLI-only (no GUI)
    minimal                 Base development

${YELLOW}EXAMPLES:${NC}
    ./build.sh switch               # Runner: activate latest GHA-built closure (default)
    ./build.sh switch local         # On-device eval+build+activate (heavy, may thrash 8GB)
    ./build.sh container-build      # Build full image
    ./build.sh compose-up           # Start with compose
    ./build.sh distrobox-create     # Create distrobox

${YELLOW}FILES:${NC}
    build.json              Configuration file
    build.log               Build log (appending)
    src/                    Nix source files
    container/              Container definitions

EOF
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    # Initialize log
    log "========== Build script started =========="

    # No arguments - show help
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi

    # Parse command
    cmd="$1"

    # ── FREEZE-SAFE ISOLATION (2026-07-10 v3.1) ──────────────────────────────
    # A heavy switch/pull (closure download + import) MUST NOT run in the
    # desktop's own cgroup (app.slice under user-1000.slice) — its memory
    # pressure thrashes the compositor and freezes the box (5× on 2026-07-10).
    # Re-exec the whole invocation, as this user, into isolation_slice (a SYSTEM
    # slice isolated from the desktop) bounded by switch_memory_max/swap_max,
    # passing the desktop session env so HM activation's `systemctl --user`
    # still reaches the user bus. SWITCH_ISOLATED guards infinite re-exec.
    if [ -z "${SWITCH_ISOLATED:-}" ] && command -v systemd-run >/dev/null 2>&1 \
       && command -v jq >/dev/null 2>&1 && [ -f "$HM_AUTO_CFG" ] \
       && [ "$(jq -r '.safety.isolate // false' "$HM_AUTO_CFG")" = "true" ]; then
        case "$cmd" in
            switch|pull|switch-remote)
                if [ "$cmd" = "switch" ] && [ "${2:-}" = "local" ]; then :; else
                    _iso_slice="$(jq -r '.safety.isolation_slice // "workload.slice"' "$HM_AUTO_CFG")"
                    _iso_mm="$(jq -r '.safety.switch_memory_max // "2G"' "$HM_AUTO_CFG")"
                    _iso_sm="$(jq -r '.safety.switch_swap_max // "4G"' "$HM_AUTO_CFG")"
                    _iso_xdg="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
                    _iso_dbus="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$_iso_xdg/bus}"
                    _iso_sudo="/run/wrappers/bin/sudo"; [ -x "$_iso_sudo" ] || _iso_sudo="sudo"
                    # Resolve the graphical session env even when launched HEADLESS
                    # (systemd timer, ssh, or a non-desktop shell like Claude's) so
                    # the MANDATORY popup ALWAYS appears + HM `systemctl --user`
                    # reaches the user bus. Prior bug: the popup only spawned when
                    # the LAUNCHING shell already had DISPLAY/WAYLAND set.
                    _iso_wl="${WAYLAND_DISPLAY:-}"; _iso_x="${DISPLAY:-}"
                    if [ -z "$_iso_wl$_iso_x" ]; then
                        for _s in "$_iso_xdg"/wayland-*; do
                            [ -S "$_s" ] && { _iso_wl="$(basename "$_s")"; break; }
                        done
                        [ -z "$_iso_wl" ] && [ -S /tmp/.X11-unix/X0 ] && _iso_x=":0"
                    fi
                    log_info "Isolating switch into $_iso_slice (mem≤$_iso_mm swap≤$_iso_sm) — the desktop can NOT be frozen by this transfer."

                    # ── MANDATORY POPUP: a Konsole window tailing build.log live
                    # (the isolated switch's per-path progress goes there via log()).
                    # Headless-safe — the konsole/notify are handed the resolved
                    # session env so they draw even when the launcher had none.
                    if [ -n "$_iso_wl$_iso_x" ] && command -v konsole >/dev/null 2>&1; then
                        command -v notify-send >/dev/null 2>&1 && \
                          WAYLAND_DISPLAY="$_iso_wl" DISPLAY="$_iso_x" XDG_RUNTIME_DIR="$_iso_xdg" DBUS_SESSION_BUS_ADDRESS="$_iso_dbus" \
                          notify-send -u critical -i system-software-update \
                            "Nix switch STARTED" "Pulling + activating. Live progress window opening. Isolated in $_iso_slice — desktop protected." >/dev/null 2>&1 || true
                        WAYLAND_DISPLAY="$_iso_wl" DISPLAY="$_iso_x" XDG_RUNTIME_DIR="$_iso_xdg" DBUS_SESSION_BUS_ADDRESS="$_iso_dbus" QT_QPA_PLATFORM="" \
                          konsole --hold -p ColorScheme=DarkPastels -p tabtitle="Nix Switch — LIVE progress" \
                            -e bash -c "echo '=== NIX SWITCH — LIVE PROGRESS (isolated in $_iso_slice) ==='; echo '--- [journal] filtered nix activity + [build.log] per-path progress ---'; ( journalctl -f -o short-iso -u hm-switch-isolated.service _COMM=nix-daemon _COMM=nix 2>/dev/null | sed 's/^/[journal] /' & ); tail -n 60 -f '$LOG_FILE'" >/dev/null 2>&1 &
                        _popup_pid=$!
                    else
                        log_warn "no graphical session resolved — switch runs headless (no popup this time)."
                    fi

                    "$_iso_sudo" systemd-run --slice="$_iso_slice" --unit=hm-switch-isolated \
                        --uid="$(id -u)" --gid="$(id -g)" --wait --collect --quiet \
                        -p MemoryHigh="$_iso_mm" -p MemoryMax="$_iso_mm" -p MemorySwapMax="$_iso_sm" \
                        --setenv=SWITCH_ISOLATED=1 --setenv=HOME="$HOME" --setenv=PATH="$PATH" \
                        --setenv=XDG_RUNTIME_DIR="$_iso_xdg" --setenv=DBUS_SESSION_BUS_ADDRESS="$_iso_dbus" \
                        --setenv=DISPLAY="$_iso_x" --setenv=WAYLAND_DISPLAY="$_iso_wl" \
                        --setenv=LANG="${LANG:-C.UTF-8}" --setenv=LC_ALL="${LC_ALL:-C.UTF-8}" \
                        --setenv=NSP_WRAPPED=1 \
                        --working-directory="$SCRIPT_DIR" \
                        "$0" "$@"
                    _iso_rc=$?
                    if [ -n "''${DISPLAY:-}''${WAYLAND_DISPLAY:-}" ] && command -v notify-send >/dev/null 2>&1; then
                        if [ "$_iso_rc" -eq 0 ]; then
                            notify-send -i system-software-update "Nix switch DONE ✓" "New generation activated successfully." || true
                        else
                            notify-send -u critical -i dialog-error "Nix switch FAILED ✗ (exit $_iso_rc)" "See the progress window / build.log." || true
                        fi
                    fi
                    exit "$_iso_rc"
                fi
                ;;
        esac
    fi

    shift

    case "$cmd" in
        # Help
        -h|--help|help)
            show_help
            ;;

        # Nix commands
        install)
            nix_install
            ;;
        switch)
            # DEFAULT = runner (GHA-built closure + activate; no freeze-prone local eval).
            # `switch local [host] [user]` = eval+build+activate on-device.
            case "${1:-runner}" in
                local)  shift; nix_switch "${1:-surface-plasma}" "${2:-diego}" ;;
                runner) [ $# -gt 0 ] && shift || :; cmd_switch_runner "${1:-surface-plasma}" "${2:-diego}" ;;
                *)      cmd_switch_runner "${1:-surface-plasma}" "${2:-diego}" ;;  # `switch <host>` → runner
            esac
            ;;
        build)
            nix_build "${1:-surface-plasma}" "${2:-diego}"
            ;;
        ci-build)
            cmd_ci_build "${1:-surface-plasma}" "${2:-diego}"
            ;;
        nixcache-publish)
            cmd_nixcache_publish
            ;;
        pull|switch-remote)
            cmd_pull "${1:-}"
            ;;
        update)
            nix_update
            ;;
        show)
            nix_show
            ;;
        develop)
            nix_develop
            ;;

        # Container commands
        container-build)
            container_build "${1:-full}"
            ;;
        container-load)
            container_load
            ;;
        container-run)
            container_run "${1:-full}"
            ;;
        container-push)
            container_push "$@"
            ;;

        # Compose commands
        compose-up)
            compose_up
            ;;
        compose-down)
            compose_down
            ;;
        compose-shell)
            compose_shell
            ;;

        # Distrobox commands
        distrobox-create)
            distrobox_create "${1:-diego-dev}"
            ;;
        distrobox-enter)
            distrobox_enter "${1:-diego-dev}"
            ;;
        distrobox-remove)
            distrobox_remove "${1:-diego-dev}"
            ;;

        # Interactive TUI
        tui|menu)
            run_tui
            ;;

        # Utility commands
        status)
            status
            ;;
        clean)
            clean
            ;;
        log)
            view_log
            ;;
        clear-log)
            clear_log
            ;;

        # Unknown
        *)
            log_error "Unknown command: $cmd"
            printf "\nRun './build.sh --help' for usage\n"
            exit 1
            ;;
    esac

    log "========== Build script finished =========="
}

# BUILDSH_SOURCE_ONLY=1 lets test scripts `. build.sh` to unit-test individual
# functions (e.g. ghcr_incremental_switch) without executing the dispatcher or
# re-exec — nothing below runs when sourced for tests.
if [ -z "${BUILDSH_SOURCE_ONLY:-}" ]; then

# The MANDATORY switch popup (notify-send + a Konsole window tailing build.log
# live) is now fired inside main()'s isolation block for switch/pull/switch-
# remote — in the outer desktop context, BEFORE isolating into workload.slice,
# so it always appears and doesn't depend on the (deploy-lagging) progress
# wrapper. The old bottom-of-file `nix-switch-progress-wrap` re-exec was removed
# (2026-07-10): the OLD deployed wrapper appended `--log-format internal-json`
# unconditionally, which build.sh does not accept, and it opened a second
# competing window. `switch local` still self-wraps inside nix_switch().
main "$@"

fi
