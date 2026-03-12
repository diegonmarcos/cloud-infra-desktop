#!/bin/sh
# ============================================================================
# Diego's Termux/nix-on-droid - Build Script
# ============================================================================
# Manages home-manager switch for mobile nix-on-droid environment
#
# Usage:
#   ./build.sh              # Apply home-manager config (switch)
#   ./build.sh tui          # Launch interactive TUI menu
#   ./build.sh update       # Update flake inputs
#   ./build.sh --help       # Show help
# ============================================================================

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
LOG_FILE="$SCRIPT_DIR/build.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================================
# LOGGING
# ============================================================================

log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
log_info()    { log "INFO: $*";    printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
log_success() { log "SUCCESS: $*"; printf "${GREEN}[OK]${NC} %s\n" "$*"; }
log_warn()    { log "WARN: $*";    printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error()   { log "ERROR: $*";   printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
log_header()  { log "=== $* ===";  printf "\n${BOLD}${CYAN}=== %s ===${NC}\n\n" "$*"; }

# ============================================================================
# CHECKS
# ============================================================================

check_nix() {
    if ! command -v nix >/dev/null 2>&1; then
        log_error "Nix not found"
        return 1
    fi
    return 0
}

check_home_manager() {
    command -v home-manager >/dev/null 2>&1
}

# ============================================================================
# COMMANDS
# ============================================================================

cmd_switch() {
    log_header "Switching to $SRC_DIR"
    check_nix || return 1

    # Stage dirty files so nix flake evaluation sees changes
    if command -v git >/dev/null 2>&1; then
        dirty=$(git -C "$SRC_DIR" status --porcelain 2>/dev/null || true)
        if [ -n "$dirty" ]; then
            log_info "Staging dirty files for flake evaluation..."
            git -C "$SRC_DIR" add -A 2>/dev/null || true
        fi
    fi

    # Clean old backup files
    backup_count=$(command find "$HOME" -maxdepth 1 -name "*.backup" -type f 2>/dev/null | wc -l)
    if [ "$backup_count" -gt 0 ]; then
        log_info "Cleaning $backup_count old backup file(s)..."
        command find "$HOME" -maxdepth 1 -name "*.backup" -type f -delete 2>/dev/null || true
    fi

    # Guard: profile must use nix-env format (manifest.nix), not nix profile
    # format (manifest.json). nix-on-droid's installPackages can't parse
    # nix profile list output from Nix 2.18+, causing duplicate entries.
    # If someone runs 'nix profile install', it converts the profile and breaks things.
    _profile="/nix/var/nix/profiles/per-user/nix-on-droid/profile"
    if [ -L "$_profile" ] && [ -f "$_profile/manifest.json" ]; then
        log_error "Profile uses 'nix profile' format (manifest.json) — incompatible with nix-on-droid"
        log_error "Use 'nix-env --profile $_profile -i <pkg>' instead of 'nix profile install'"
        return 1
    fi

    log_info "Applying nix-on-droid configuration..."

    _rc_file=$(mktemp)
    { nix-on-droid switch --flake "$SRC_DIR" 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
    exit_code=$(cat "$_rc_file")
    rm -f "$_rc_file"

    if [ "$exit_code" -ne 0 ]; then
        log_error "Configuration failed (exit $exit_code)"
        log_info "Check $LOG_FILE for details"
        return $exit_code
    fi

    log_success "Configuration applied: $SRC_DIR"
}

cmd_update() {
    log_header "Updating Flake Inputs"
    check_nix || return 1

    cd "$SRC_DIR"
    log_info "Updating flake.lock..."

    _rc_file=$(mktemp)
    { nix flake update 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
    exit_code=$(cat "$_rc_file")
    rm -f "$_rc_file"

    if [ "$exit_code" -ne 0 ]; then
        log_error "Flake update failed (exit $exit_code)"
        return $exit_code
    fi

    log_success "Flake inputs updated"
}

cmd_show() {
    log_header "Flake Outputs"
    check_nix || return 1
    cd "$SRC_DIR"
    nix flake show
}

cmd_build() {
    log_header "Building $SRC_DIR (no apply)"
    check_nix || return 1

    if command -v git >/dev/null 2>&1; then
        dirty=$(git -C "$SRC_DIR" status --porcelain 2>/dev/null || true)
        if [ -n "$dirty" ]; then
            log_info "Staging dirty files for flake evaluation..."
            git -C "$SRC_DIR" add -A 2>/dev/null || true
        fi
    fi

    log_info "Building activation package..."
    _nix="nix"
    [ -x "$HOME/.nix-profile/bin/nix" ] && _nix="$HOME/.nix-profile/bin/nix"
    _rc_file=$(mktemp)
    { BUILDSH_GUARDRAIL=1 "$_nix" build "$SRC_DIR#nixOnDroidConfigurations.default.activationPackage" --impure --no-link 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
    exit_code=$(cat "$_rc_file")
    rm -f "$_rc_file"

    if [ "$exit_code" -ne 0 ]; then
        log_error "Build failed (exit $exit_code)"
        return $exit_code
    fi

    log_success "Build succeeded (not applied — use 'switch' to apply)"
}

cmd_dry_run() {
    log_header "Dry run — $SRC_DIR"
    check_nix || return 1

    if command -v git >/dev/null 2>&1; then
        dirty=$(git -C "$SRC_DIR" status --porcelain 2>/dev/null || true)
        if [ -n "$dirty" ]; then
            log_info "Staging dirty files for flake evaluation..."
            git -C "$SRC_DIR" add -A 2>/dev/null || true
        fi
    fi

    log_info "Evaluating what would be built..."
    _nix="nix"
    [ -x "$HOME/.nix-profile/bin/nix" ] && _nix="$HOME/.nix-profile/bin/nix"
    BUILDSH_GUARDRAIL=1 "$_nix" build "$SRC_DIR#nixOnDroidConfigurations.default.activationPackage" --impure --no-link --dry-run 2>&1 | tee -a "$LOG_FILE"
}

cmd_check() {
    log_header "Flake Check"
    check_nix || return 1
    cd "$SRC_DIR"
    nix flake check
}

cmd_clean() {
    log_header "Cleaning"

    log_info "Removing result symlinks..."
    rm -f "$SRC_DIR/result" "$SRC_DIR/result-*"

    log_info "Trimming generations (keep last 3)..."
    nix-env --delete-generations +3 2>&1 || true

    log_info "Nix garbage collection..."
    if check_nix 2>/dev/null; then
        nix-collect-garbage 2>&1 | tee -a "$LOG_FILE"
    fi

    log_success "Cleanup complete"
}

cmd_status() {
    log_header "Status"

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

    printf "${BOLD}System:${NC} %s (%s)\n" "$(uname -s)" "$(uname -m)"
    printf "${BOLD}User:${NC} %s\n" "$(whoami)"
    printf "${BOLD}Home:${NC} %s\n" "$HOME"
    printf "${BOLD}Flake:${NC} %s\n" "$SRC_DIR/flake.nix"

    printf "\n${BOLD}Installed (nix-env):${NC}\n"
    nix-env --query 2>/dev/null | sed 's/^/  /'
}

# ============================================================================
# TUI MENU
# ============================================================================

run_tui() {
    while true; do
        clear
        printf "${CYAN}"
        cat << 'EOF'
  _____                              _   _ _
 |_   _|__ _ __ _ __ ___  _   ___  | \ | (_)_  __
   | |/ _ \ '__| '_ ` _ \| | | \ \/ /  |  \| | \ \/ /
   | |  __/ |  | | | | | | |_| |>  <   | |\  | |>  <
   |_|\___|_|  |_| |_| |_|\__,_/_/\_\  |_| \_|_/_/\_\
EOF
        printf "${NC}\n"
        printf "  nix-on-droid Home Manager\n\n"

        printf "${YELLOW}Commands:${NC}\n"
        printf "  ${GREEN}1)${NC} Switch    - Apply home-manager config\n"
        printf "  ${GREEN}2)${NC} Update    - Update flake inputs\n"
        printf "  ${GREEN}3)${NC} Show      - Display flake outputs\n"
        printf "  ${GREEN}4)${NC} Check     - Validate flake\n"
        printf "  ${GREEN}5)${NC} Status    - System info\n"
        printf "  ${GREEN}6)${NC} Clean     - Garbage collect\n"
        printf "  ${GREEN}7)${NC} Log       - View build log\n"
        printf "  ${RED}q)${NC}  Quit\n\n"

        printf "${BOLD}Choice: ${NC}"
        read -r choice

        case "$choice" in
            1) cmd_switch; printf "\nPress Enter..."; read -r _ ;;
            2) cmd_update; printf "\nPress Enter..."; read -r _ ;;
            3) cmd_show; printf "\nPress Enter..."; read -r _ ;;
            4) cmd_check; printf "\nPress Enter..."; read -r _ ;;
            5) cmd_status; printf "\nPress Enter..."; read -r _ ;;
            6) cmd_clean; printf "\nPress Enter..."; read -r _ ;;
            7) ${PAGER:-less} "$LOG_FILE" 2>/dev/null || log_info "No log file" ;;
            q|Q) printf "\n${GREEN}Bye${NC}\n"; exit 0 ;;
            *) log_warn "Invalid: $choice"; sleep 1 ;;
        esac
    done
}

# ============================================================================
# HELP
# ============================================================================

show_help() {
    cat << EOF
${BOLD}Termux/nix-on-droid Home Manager${NC}

${YELLOW}USAGE:${NC}
    ./build.sh              Apply config (switch, default)
    ./build.sh <command>    Run command

${YELLOW}COMMANDS:${NC}
    switch      Apply home-manager config (default)
    build       Build without applying (validate only)
    dry-run     Show what would be built (fast, no build)
    plan        Alias for dry-run
    tui         Launch interactive TUI menu
    update      Update flake inputs
    show        Show flake outputs
    check       Validate flake
    status      System info
    clean       Garbage collect
    log         View build log

${YELLOW}EXAMPLES:${NC}
    ./build.sh              # Apply config (same as switch)
    ./build.sh tui          # Interactive menu
    ./build.sh update       # Update nixpkgs
EOF
}

# ============================================================================
# MAIN
# ============================================================================

log "========== Build script started =========="

case "${1:-switch}" in
    -h|--help|help) show_help ;;
    switch)  cmd_switch ;;
    build)   cmd_build ;;
    dry-run|plan) cmd_dry_run ;;
    tui)     run_tui ;;
    update)  cmd_update ;;
    show)    cmd_show ;;
    check)   cmd_check ;;
    status)  cmd_status ;;
    clean)   cmd_clean ;;
    log)     ${PAGER:-less} "$LOG_FILE" 2>/dev/null || log_info "No log file" ;;
    *)       log_error "Unknown: $1"; show_help; exit 1 ;;
esac

log "========== Build script finished =========="
