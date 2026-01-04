#!/bin/bash
set -e

# ═══════════════════════════════════════════════════════════════════════════
# PODMAN MINIMUM - Container Build Script
# Config: config.json
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"

# ═══════════════════════════════════════════════════════════════════════════
# COLORS & STYLES
# ═══════════════════════════════════════════════════════════════════════════
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

FILL="█"
EMPTY="░"

# Load config
if [[ -f "$CONFIG_FILE" ]]; then
    CONTAINER_NAME=$(jq -r '.container.name' "$CONFIG_FILE")
    IMAGE_NAME=$(jq -r '.container.image' "$CONFIG_FILE")
else
    CONTAINER_NAME="cloud-minimum"
    IMAGE_NAME="cloud-connect:minimum"
fi

# Simple logging for non-TUI commands
log() { echo -e "[$(date +%H:%M:%S)] $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ═══════════════════════════════════════════════════════════════════════════
# TUI PROGRESS FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

HEADER_HEIGHT=10
LOG_HEIGHT=15
TOTAL_STEPS=4
CURRENT_STEP=0
STEP_START_TIME=0
START_TIME=0
COMPLETED_WORK=0
TOTAL_WORK=100
STEP_WORK=0
STEP_WORK_DONE=0

STEP_NAMES=(
    ""
    "Checking Dependencies"
    "Installing Dependencies"
    "Building Image"
    "Finalizing"
)

STEP_COLORS=("" "$YELLOW" "$BLUE" "$MAGENTA" "$GREEN")

declare -a LOG_BUFFER
LOG_BUFFER_SIZE=$((LOG_HEIGHT - 4))

move_to() { printf '\033[%d;%dH' "$1" "$2"; }
hide_cursor() { printf '\033[?25l'; }
show_cursor() { printf '\033[?25h'; }

draw_progress_bar() {
    local percent=$1
    local width=$2
    local color=$3
    local filled=$((percent * width / 100))
    local empty=$((width - filled))

    printf "${color}"
    for ((i=0; i<filled; i++)); do printf "${FILL}"; done
    printf "${DIM}"
    for ((i=0; i<empty; i++)); do printf "${EMPTY}"; done
    printf "${NC}"
}

format_time() {
    local secs=$1
    if ((secs < 60)); then
        printf "%ds" "$secs"
    elif ((secs < 3600)); then
        printf "%dm %ds" $((secs/60)) $((secs%60))
    else
        printf "%dh %dm" $((secs/3600)) $(((secs%3600)/60))
    fi
}

format_size() {
    local mb=$1
    if ((mb < 1024)); then
        printf "%dMB" "$mb"
    else
        printf "%.1fGB" "$(echo "scale=1; $mb/1024" | bc)"
    fi
}

draw_overall_box() {
    local overall_percent=$((COMPLETED_WORK * 100 / TOTAL_WORK))
    ((overall_percent > 100)) && overall_percent=100

    local elapsed=$(($(date +%s) - START_TIME))
    local work_left=$((TOTAL_WORK - COMPLETED_WORK))

    local eta=0
    if ((COMPLETED_WORK > 0 && elapsed > 0)); then
        local speed=$((COMPLETED_WORK / elapsed))
        ((speed > 0)) && eta=$((work_left / speed))
    else
        eta=$((work_left / 2))
    fi

    move_to 1 1
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${NC}  ${WHITE}${BOLD}PODMAN CONTAINER BUILD${NC}                                           ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╠══════════════════════════════════════════════════════════════════════╣${NC}"
    printf "${MAGENTA}║${NC}  Overall: "
    draw_progress_bar $overall_percent 40 "$GREEN"
    printf " ${WHITE}%3d%%${NC}               ${MAGENTA}║${NC}\n" "$overall_percent"
    echo -e "${MAGENTA}╠══════════════════════════════════════════════════════════════════════╣${NC}"
    printf "${MAGENTA}║${NC}  ${WHITE}Elapsed:${NC}  %-12s ${WHITE}ETA:${NC} %-12s                      ${MAGENTA}║${NC}\n" "$(format_time $elapsed)" "$(format_time $eta)"
    printf "${MAGENTA}║${NC}  ${WHITE}Done:${NC}     %-12s ${WHITE}Left:${NC} %-12s                     ${MAGENTA}║${NC}\n" "$(format_size $COMPLETED_WORK)" "$(format_size $work_left)"
    echo -e "${MAGENTA}╠══════════════════════════════════════════════════════════════════════╣${NC}"

    printf "${MAGENTA}║${NC}  "
    for ((i=1; i<=TOTAL_STEPS; i++)); do
        if ((i < CURRENT_STEP)); then
            printf "${GREEN}●${NC}"
        elif ((i == CURRENT_STEP)); then
            printf "${YELLOW}◉${NC}"
        else
            printf "${DIM}○${NC}"
        fi
    done
    printf "  Step %d/%d: %-36s ${MAGENTA}║${NC}\n" "$CURRENT_STEP" "$TOTAL_STEPS" "${STEP_NAMES[$CURRENT_STEP]}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════════════╝${NC}"
}

draw_step_box() {
    local step_percent=${1:-0}
    local step_name="${STEP_NAMES[$CURRENT_STEP]}"
    local step_color="${STEP_COLORS[$CURRENT_STEP]}"
    local step_elapsed=$(($(date +%s) - STEP_START_TIME))

    local step_left=$((STEP_WORK - STEP_WORK_DONE))
    local step_eta=0
    if ((STEP_WORK_DONE > 0 && step_elapsed > 0)); then
        local step_speed=$((STEP_WORK_DONE / step_elapsed))
        ((step_speed > 0)) && step_eta=$((step_left / step_speed))
    fi

    move_to $((HEADER_HEIGHT + 1)) 1

    echo -e "${step_color}┌──────────────────────────────────────────────────────────────────────┐${NC}"
    printf "${step_color}│${NC}  ${WHITE}${BOLD}Step %d:${NC} %-56s ${step_color}│${NC}\n" "$CURRENT_STEP" "$step_name"
    printf "${step_color}│${NC}  "
    draw_progress_bar $step_percent 45 "$step_color"
    printf " ${WHITE}%3d%%${NC}  ~%-8s ${step_color}│${NC}\n" "$step_percent" "$(format_time $step_eta)"
    echo -e "${step_color}├──────────────────────────────────────────────────────────────────────┤${NC}"

    local log_start=$((${#LOG_BUFFER[@]} - LOG_BUFFER_SIZE))
    ((log_start < 0)) && log_start=0

    for ((i=0; i<LOG_BUFFER_SIZE; i++)); do
        local idx=$((log_start + i))
        local line=""
        if ((idx >= 0 && idx < ${#LOG_BUFFER[@]})); then
            line="${LOG_BUFFER[$idx]}"
        fi
        line="${line:0:68}"
        printf "${step_color}│${NC}  ${DIM}%-68s${NC}${step_color}│${NC}\n" "$line"
    done

    echo -e "${step_color}└──────────────────────────────────────────────────────────────────────┘${NC}"
}

log_progress() {
    local msg=$1
    local step_percent=$2
    local work_add=${3:-0}

    STEP_WORK_DONE=$((STEP_WORK_DONE + work_add))
    COMPLETED_WORK=$((COMPLETED_WORK + work_add))

    LOG_BUFFER+=("$(date +%H:%M:%S) $msg")
    draw_overall_box
    draw_step_box "$step_percent"
}

start_step() {
    CURRENT_STEP=$1
    STEP_WORK=$2
    STEP_START_TIME=$(date +%s)
    STEP_WORK_DONE=0
    LOG_BUFFER=()
    draw_overall_box
    draw_step_box 0
}

# ═══════════════════════════════════════════════════════════════════════════
# DEPENDENCY CHECK
# ═══════════════════════════════════════════════════════════════════════════

PODMAN_DEPS=(podman podman-compose fuse-overlayfs slirp4netns crun)

check_deps_silent() {
    for dep in "${PODMAN_DEPS[@]}"; do
        if ! command -v "$dep" &>/dev/null && ! pacman -Qi "$dep" &>/dev/null 2>&1; then
            return 1
        fi
    done
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# BUILD COMMAND WITH TUI
# ═══════════════════════════════════════════════════════════════════════════

cmd_build() {
    clear
    hide_cursor
    trap 'show_cursor; exit' EXIT INT TERM

    START_TIME=$(date +%s)
    TOTAL_WORK=2500  # Estimated MB for container build
    COMPLETED_WORK=0

    # ═══════════════════════════════════════════════════════════════════════
    # STEP 1: Check Dependencies
    # ═══════════════════════════════════════════════════════════════════════
    start_step 1 10

    log_progress "Checking podman dependencies..." 20 2
    MISSING_DEPS=()
    for dep in "${PODMAN_DEPS[@]}"; do
        if command -v "$dep" &>/dev/null || pacman -Qi "$dep" &>/dev/null 2>&1; then
            log_progress "✓ $dep" 50 1
        else
            log_progress "✗ $dep (missing)" 50 1
            MISSING_DEPS+=("$dep")
        fi
    done

    if [[ ${#MISSING_DEPS[@]} -eq 0 ]]; then
        log_progress "✓ All dependencies installed" 100 2
        sleep 1
    else
        log_progress "Missing: ${MISSING_DEPS[*]}" 100 0
        sleep 1

        # ═══════════════════════════════════════════════════════════════════
        # STEP 2: Install Dependencies
        # ═══════════════════════════════════════════════════════════════════
        start_step 2 100

        log_progress "Installing missing dependencies..." 10 0

        if [[ $EUID -ne 0 ]]; then
            log_progress "Using sudo to install..." 20 10
            sudo pacman -S --noconfirm --needed "${MISSING_DEPS[@]}" > /dev/null 2>&1
        else
            pacman -S --noconfirm --needed "${MISSING_DEPS[@]}" > /dev/null 2>&1
        fi

        for dep in "${MISSING_DEPS[@]}"; do
            log_progress "✓ Installed $dep" 80 20
        done

        log_progress "✓ Dependencies installed" 100 10
        sleep 1
    fi

    # ═══════════════════════════════════════════════════════════════════════
    # STEP 3: Build Container Image
    # ═══════════════════════════════════════════════════════════════════════
    start_step 3 2300

    cd "$SCRIPT_DIR"

    if [[ ! -f "Containerfile" ]]; then
        log_progress "ERROR: Containerfile not found!" 100 0
        show_cursor
        exit 1
    fi

    log_progress "Building image: $IMAGE_NAME" 5 50

    # Run podman build and capture output for progress
    podman build -t "$IMAGE_NAME" -f Containerfile . 2>&1 | while IFS= read -r line; do
        if [[ "$line" =~ ^STEP\ ([0-9]+)/([0-9]+) ]]; then
            step_num="${BASH_REMATCH[1]}"
            step_total="${BASH_REMATCH[2]}"
            pct=$((step_num * 100 / step_total))
            work=$((step_num * 2000 / step_total))
            log_progress "Container step $step_num/$step_total" $pct $((work / step_total))
        elif [[ "$line" == *"Downloading"* ]] || [[ "$line" == *"Installing"* ]]; then
            short="${line:0:60}"
            log_progress "$short" 50 5
        elif [[ "$line" == *"COMMIT"* ]]; then
            log_progress "Committing image..." 95 50
        fi
    done

    log_progress "✓ Image built: $IMAGE_NAME" 100 100
    sleep 1

    # ═══════════════════════════════════════════════════════════════════════
    # STEP 4: Finalize
    # ═══════════════════════════════════════════════════════════════════════
    start_step 4 50

    log_progress "Verifying image..." 30 10

    IMAGE_SIZE=$(podman images --format "{{.Size}}" "$IMAGE_NAME" 2>/dev/null | head -1)
    log_progress "Image size: $IMAGE_SIZE" 60 20

    log_progress "✓ Build complete!" 100 20
    sleep 1

    # ═══════════════════════════════════════════════════════════════════════
    # SUMMARY
    # ═══════════════════════════════════════════════════════════════════════
    TOTAL_TIME=$(($(date +%s) - START_TIME))

    clear
    show_cursor

    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${NC}               ${WHITE}${BOLD}CONTAINER BUILD COMPLETE${NC}                            ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╠══════════════════════════════════════════════════════════════════════╣${NC}"
    printf "${MAGENTA}║${NC}  Total time: ${WHITE}%-56s${NC}${MAGENTA}║${NC}\n" "$(format_time $TOTAL_TIME)"
    printf "${MAGENTA}║${NC}  Image:      ${WHITE}%-56s${NC}${MAGENTA}║${NC}\n" "$IMAGE_NAME"
    printf "${MAGENTA}║${NC}  Size:       ${WHITE}%-56s${NC}${MAGENTA}║${NC}\n" "$IMAGE_SIZE"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════════════╝${NC}"

    echo ""
    echo -e "${WHITE}Next steps:${NC}"
    echo -e "  ${CYAN}./build.sh start${NC}  - Start container"
    echo -e "  ${CYAN}./build.sh shell${NC}  - Enter container shell"
    echo -e "  ${CYAN}./build.sh status${NC} - Show status"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# OTHER COMMANDS (simple, no TUI)
# ═══════════════════════════════════════════════════════════════════════════

cmd_start() {
    log "Starting container..."

    if ! check_deps_silent; then
        error "Dependencies missing. Run: ./build.sh build"
    fi

    cd "$SCRIPT_DIR"
    podman-compose up -d

    success "Container started!"
    log "Enter with: ${CYAN}./build.sh shell${NC}"
}

cmd_stop() {
    log "Stopping container..."
    cd "$SCRIPT_DIR"
    podman-compose down
    success "Container stopped"
}

cmd_shell() {
    log "Entering container shell..."

    if ! podman ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        warn "Container not running. Starting..."
        cmd_start
    fi

    podman exec -it "$CONTAINER_NAME" bash
}

cmd_status() {
    echo -e "${WHITE}Container Status:${NC}"
    podman ps -a --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo -e "${WHITE}Image:${NC}"
    podman images --filter "reference=$IMAGE_NAME" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.Created}}"
}

cmd_clean() {
    log "Removing container and image..."
    cd "$SCRIPT_DIR"
    podman-compose down 2>/dev/null || true
    podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
    podman rmi "$IMAGE_NAME" 2>/dev/null || true
    success "Cleaned"
}

cmd_deps() {
    echo -e "${WHITE}Podman Dependencies:${NC}"
    for dep in "${PODMAN_DEPS[@]}"; do
        if command -v "$dep" &>/dev/null || pacman -Qi "$dep" &>/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} $dep"
        else
            echo -e "  ${RED}✗${NC} $dep"
        fi
    done
    echo ""

    if ! check_deps_silent; then
        read -p "Install missing dependencies? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo pacman -S --noconfirm --needed "${PODMAN_DEPS[@]}"
            success "Dependencies installed"
        fi
    fi
}

cmd_logs() {
    podman logs -f "$CONTAINER_NAME"
}

cmd_help() {
    echo -e "${MAGENTA}Podman Minimum - Container Build Script${NC}"
    echo ""
    echo -e "${WHITE}Usage:${NC} $0 <command>"
    echo ""
    echo -e "${WHITE}Commands:${NC}"
    echo "  deps     Check/install podman dependencies"
    echo "  build    Build container image (TUI with progress)"
    echo "  start    Start container"
    echo "  stop     Stop container"
    echo "  shell    Enter container shell"
    echo "  status   Show container/image status"
    echo "  logs     Follow container logs"
    echo "  clean    Remove container and image"
    echo ""
    echo -e "${WHITE}Config:${NC} $CONFIG_FILE"
    echo -e "${WHITE}Image:${NC}  $IMAGE_NAME"
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

case "${1:-}" in
    deps)   cmd_deps ;;
    build)  cmd_build ;;
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    shell)  cmd_shell ;;
    status) cmd_status ;;
    logs)   cmd_logs ;;
    clean)  cmd_clean ;;
    help|--help|-h) cmd_help ;;
    *)
        cmd_help
        exit 1
        ;;
esac
