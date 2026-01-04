#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                         B_TOOLS - Unified Builder                         ║
# ║                                                                           ║
# ║   Build toolsets for Docker, Podman, or direct host installation         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   ./build.sh                    # Interactive TUI
#   ./build.sh docker min         # Build Docker with min profile
#   ./build.sh podman basic       # Build Podman with basic profile
#   ./build.sh host full          # Install on host with full profile
#   ./build.sh --help             # Show help

set -e

# ═══════════════════════════════════════════════════════════════════════════
# PATHS
# ═══════════════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/tools_profiles"
SRC_DOCKER="$SCRIPT_DIR/src_docker"
SRC_PODMAN="$SCRIPT_DIR/src_podman"
SRC_HOST="$SCRIPT_DIR/src_host"
DIST_DOCKER="$SCRIPT_DIR/dist_docker"
DIST_PODMAN="$SCRIPT_DIR/dist_podman"
DIST_HOST="$SCRIPT_DIR/dist_host"

# ═══════════════════════════════════════════════════════════════════════════
# COLORS (ANSI)
# ═══════════════════════════════════════════════════════════════════════════
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    DIM='\033[2m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' DIM='' BOLD='' NC=''
fi

# ═══════════════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════════════
log()   { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[-]${NC} %s\n" "$1"; exit 1; }
info()  { printf "${CYAN}[i]${NC} %s\n" "$1"; }

clear_screen() { printf '\033[2J\033[H'; }

draw_box() {
    title="$1"
    printf "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║${NC}  ${BOLD}%-61s${NC} ${CYAN}║${NC}\n" "$title"
    printf "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}\n"
}

draw_separator() {
    printf "${DIM}─────────────────────────────────────────────────────────────────${NC}\n"
}

# ═══════════════════════════════════════════════════════════════════════════
# DETECT DISTRO
# ═══════════════════════════════════════════════════════════════════════════
detect_distro() {
    if [ -f /etc/arch-release ]; then
        DISTRO="arch"
        PKG_INSTALL="sudo pacman -S --noconfirm"
        PKG_UPDATE="sudo pacman -Syu --noconfirm"
    elif [ -f /etc/fedora-release ]; then
        DISTRO="fedora"
        PKG_INSTALL="sudo dnf install -y"
        PKG_UPDATE="sudo dnf update -y"
    elif [ -f /etc/debian_version ]; then
        DISTRO="debian"
        PKG_INSTALL="sudo apt-get install -y"
        PKG_UPDATE="sudo apt-get update && sudo apt-get upgrade -y"
    else
        DISTRO="unknown"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# LOAD PACKAGE CONFIG
# ═══════════════════════════════════════════════════════════════════════════
load_config() {
    profile="$1"
    config_file="$TOOLS_DIR/${profile}.conf"

    if [ ! -f "$config_file" ]; then
        error "Config file not found: $config_file"
    fi

    # Source the config file
    . "$config_file"
}

get_packages() {
    category="$1"
    distro="$2"
    var_name="${category}_${distro}"
    eval "echo \"\${$var_name:-}\""
}

# ═══════════════════════════════════════════════════════════════════════════
# BUILD FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════
build_docker() {
    profile="$1"
    log "Building Docker image with profile: $profile"
    load_config "$profile"

    # Generate Containerfile from template with packages
    generate_containerfile "$profile" "$SRC_DOCKER/Containerfile"

    cd "$SRC_DOCKER"
    if command -v docker >/dev/null 2>&1; then
        docker build -t "b_tools:$profile" .
        log "Docker image built: b_tools:$profile"
    else
        error "Docker not found"
    fi
}

build_podman() {
    profile="$1"
    log "Building Podman image with profile: $profile"
    load_config "$profile"

    # Generate Containerfile from template with packages
    generate_containerfile "$profile" "$SRC_PODMAN/Containerfile"

    cd "$SRC_PODMAN"
    if command -v podman >/dev/null 2>&1; then
        podman build -t "b_tools:$profile" .
        log "Podman image built: b_tools:$profile"
    else
        error "Podman not found"
    fi
}

build_host() {
    profile="$1"
    log "Installing on host with profile: $profile"

    detect_distro
    if [ "$DISTRO" = "unknown" ]; then
        error "Unsupported distribution"
    fi

    load_config "$profile"

    info "Detected: $DISTRO"
    info "Updating system..."
    eval "$PKG_UPDATE" || warn "Update failed, continuing..."

    # Install each category
    for category in BASE SHELL MODERN NETWORK PRIVACY COMPILER LANG SANDBOX DESKTOP GUI; do
        packages=$(get_packages "$category" "$DISTRO")
        if [ -n "$packages" ]; then
            info "Installing $category..."
            eval "$PKG_INSTALL $packages" || warn "Some $category packages failed"
        fi
    done

    # Install npm packages
    if command -v npm >/dev/null 2>&1 && [ -n "${AI_npm:-}" ]; then
        info "Installing AI tools via npm..."
        for pkg in $AI_npm; do
            sudo npm install -g "$pkg" || warn "Failed: $pkg"
        done
    fi

    # Install pip packages
    if command -v pipx >/dev/null 2>&1 && [ -n "${SANDBOX_pip:-}" ]; then
        info "Installing pip tools..."
        for pkg in $SANDBOX_pip; do
            pipx install "$pkg" || warn "Failed: $pkg"
        done
    fi

    log "Host installation complete!"
}

generate_containerfile() {
    profile="$1"
    output="$2"

    # Get all arch packages (container base is arch)
    all_packages=""
    for category in BASE SHELL MODERN NETWORK PRIVACY COMPILER LANG SANDBOX DESKTOP GUI; do
        packages=$(get_packages "$category" "arch")
        all_packages="$all_packages $packages"
    done

    cat > "$output" << 'CONTAINERFILE_HEAD'
# ═══════════════════════════════════════════════════════════════════════════
# B_TOOLS Container
# Auto-generated - do not edit directly
# ═══════════════════════════════════════════════════════════════════════════
FROM archlinux:latest

# Update and install packages
RUN pacman -Syu --noconfirm && \
CONTAINERFILE_HEAD

    printf "    pacman -S --noconfirm %s && \\\\\n" "$all_packages" >> "$output"

    cat >> "$output" << 'CONTAINERFILE_TAIL'
    pacman -Scc --noconfirm

# Create user
RUN useradd -m -s /bin/bash user && \
    echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install npm global packages
RUN npm install -g @anthropic-ai/claude-code @google/gemini-cli || true

USER user
WORKDIR /home/user
CMD ["/bin/bash"]
CONTAINERFILE_TAIL

    info "Generated: $output"
}

# ═══════════════════════════════════════════════════════════════════════════
# TUI MENU
# ═══════════════════════════════════════════════════════════════════════════
show_menu() {
    clear_screen

    printf "\n"
    draw_box "B_TOOLS - Unified Builder"
    printf "\n"

    printf "  ${WHITE}Select Target:${NC}\n"
    printf "    ${CYAN}1${NC}) Docker     ${DIM}(container isolation)${NC}\n"
    printf "    ${CYAN}2${NC}) Podman     ${DIM}(rootless containers)${NC}\n"
    printf "    ${CYAN}3${NC}) Host       ${DIM}(direct installation)${NC}\n"
    printf "\n"
    draw_separator
    printf "\n"

    printf "  ${WHITE}Select Profile:${NC}\n"
    printf "    ${GREEN}a${NC}) min        ${DIM}~2GB - CLI + privacy + AI${NC}\n"
    printf "    ${YELLOW}b${NC}) basic      ${DIM}~6GB - min + compilers + GUI${NC}\n"
    printf "    ${MAGENTA}c${NC}) full       ${DIM}~8GB - basic + nix${NC}\n"
    printf "\n"
    draw_separator
    printf "\n"

    printf "  ${DIM}q) Quit${NC}\n"
    printf "\n"
}

read_choice() {
    printf "  ${BOLD}Enter choice [1-3][a-c]:${NC} "
    read -r choice
    echo "$choice"
}

run_tui() {
    target=""
    profile=""

    while true; do
        show_menu
        choice=$(read_choice)

        case "$choice" in
            1|docker)  target="docker" ;;
            2|podman)  target="podman" ;;
            3|host)    target="host" ;;
            a|min)     profile="min" ;;
            b|basic)   profile="basic" ;;
            c|full)    profile="full" ;;
            q|quit)    exit 0 ;;
            *)
                # Check if it's a combined choice like "1a" or "2b"
                if [ ${#choice} -eq 2 ]; then
                    t_char=$(echo "$choice" | cut -c1)
                    p_char=$(echo "$choice" | cut -c2)

                    case "$t_char" in
                        1) target="docker" ;;
                        2) target="podman" ;;
                        3) target="host" ;;
                    esac

                    case "$p_char" in
                        a) profile="min" ;;
                        b) profile="basic" ;;
                        c) profile="full" ;;
                    esac
                fi
                ;;
        esac

        # If both selected, build
        if [ -n "$target" ] && [ -n "$profile" ]; then
            printf "\n"
            draw_separator
            info "Building: $target with $profile profile"
            draw_separator
            printf "\n"

            case "$target" in
                docker) build_docker "$profile" ;;
                podman) build_podman "$profile" ;;
                host)   build_host "$profile" ;;
            esac

            printf "\n"
            printf "  ${GREEN}Done!${NC} Press Enter to continue..."
            read -r _
            target=""
            profile=""
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# HELP
# ═══════════════════════════════════════════════════════════════════════════
show_help() {
    cat << 'EOF'
B_TOOLS - Unified Builder

Usage:
  ./build.sh                     Interactive TUI menu
  ./build.sh <target> <profile>  Direct build
  ./build.sh --help              Show this help

Targets:
  docker    Build Docker container image
  podman    Build Podman container image
  host      Install directly on host system

Profiles:
  min       Minimum (~2GB) - CLI, privacy, AI tools
  basic     Basic (~6GB)   - min + compilers, GUI apps
  full      Full (~8GB)    - basic + nix package manager

Examples:
  ./build.sh docker min      Build minimal Docker image
  ./build.sh podman basic    Build basic Podman image
  ./build.sh host full       Install full profile on host

Config files: tools_profiles/*.conf
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════
main() {
    case "${1:-}" in
        -h|--help|help)
            show_help
            ;;
        docker|podman|host)
            target="$1"
            profile="${2:-min}"

            if [ ! -f "$TOOLS_DIR/${profile}.conf" ]; then
                error "Unknown profile: $profile (available: min, basic, full)"
            fi

            case "$target" in
                docker) build_docker "$profile" ;;
                podman) build_podman "$profile" ;;
                host)   build_host "$profile" ;;
            esac
            ;;
        "")
            run_tui
            ;;
        *)
            error "Unknown command: $1 (use --help for usage)"
            ;;
    esac
}

main "$@"
