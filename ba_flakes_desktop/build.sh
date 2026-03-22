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

# Auto-confirm guardrail prompts — build.sh is the sanctioned interface
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

    # Clean old backup files that block home-manager activation
    perf_step "clean backups"
    backup_count=$(command find "$HOME" -maxdepth 1 -name "*.backup" -type f 2>/dev/null | wc -l)
    if [ "$backup_count" -gt 0 ]; then
        log_info "Cleaning $backup_count old backup file(s)..."
        command find "$HOME" -maxdepth 1 -name "*.backup" -type f -delete 2>/dev/null || true
    fi

    perf_step "home-manager switch"
    log_info "Applying Home Manager configuration..."

    # Capture exit code from the actual command, not tee
    # Use -b backup to automatically backup conflicting files
    _rc_file=$(mktemp)
    if check_home_manager 2>/dev/null; then
        { home-manager switch --impure -b backup --flake "$flake_ref" 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
    else
        { nix run home-manager -- switch --impure -b backup --flake "$flake_ref" 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
    fi
    exit_code=$(cat "$_rc_file" 2>/dev/null)
    rm -f "$_rc_file"

    # Default to 0 if exit_code is empty
    exit_code=${exit_code:-0}

    if [ "$exit_code" -ne 0 ]; then
        log_error "Configuration failed with exit code $exit_code"
        log_info "Check $LOG_FILE for details"
        perf_end
        return $exit_code
    fi

    perf_end
    log_success "Configuration applied: $flake_ref"
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

    # Default to 0 if exit_code is empty
    exit_code=${exit_code:-0}

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
    switch [host]           Apply Home Manager config (default: surface)
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
    ./build.sh switch surface       # Apply surface config
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
            nix_switch "${1:-surface}" "${2:-diego}"
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

main "$@"
