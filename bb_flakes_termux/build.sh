#!/bin/sh
# ============================================================================
# Diego's Termux/nix-on-droid - Build Script
# ============================================================================
# Manages home-manager switch for mobile nix-on-droid environment
#
# Usage:
#   ./build.sh              # Launch TUI menu
#   ./build.sh switch       # Apply home-manager config
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

    # Workaround: nix-on-droid's installPackages uses old nix profile list format
    # (space-delimited) but Nix 2.18+ uses multi-line key-value format.
    # This causes stale nix-on-droid-path entries to accumulate.
    # Clean them before switch so the activation's install step succeeds.
    _profile="/nix/var/nix/profiles/per-user/nix-on-droid/profile"
    if [ -L "$_profile" ]; then
        _raw=$(nix profile list --profile "$_profile" 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*m//g' || true)
        _indices=$(printf '%s\n' "$_raw" \
            | awk '/^Index:/{idx=$2} /nix-on-droid-path/{print idx}')
        _count=$(printf '%s\n' "$_indices" | grep -c '[0-9]' || true)
        if [ "$_count" -gt 0 ]; then
            # Save store path before removal — PATH references the profile
            # symlink's bin/, which empties when entries are removed.
            _droid_store=$(printf '%s\n' "$_raw" \
                | awk '/nix-on-droid-path/{print $NF; exit}')
            log_info "Removing $_count stale nix-on-droid-path profile entries..."
            printf '%s\n' "$_indices" | sort -rn | while read -r idx; do
                nix profile remove --profile "$_profile" "$idx" 2>/dev/null || true
            done
            # Restore PATH: store path persists until GC even after profile removal
            if [ -n "$_droid_store" ] && [ -d "$_droid_store/bin" ]; then
                export PATH="$_droid_store/bin:$PATH"
            fi
        fi
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

    # Fallback: if upstream installPackages didn't re-add nix-on-droid-path
    # (broken parser on Nix 2.18+), install it from the system generation.
    _raw_post=$(nix profile list --profile "$_profile" 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' || true)
    _has_path=$(printf '%s\n' "$_raw_post" | grep -c 'nix-on-droid-path' || true)
    if [ "$_has_path" -eq 0 ]; then
        log_warn "nix-on-droid-path missing after switch — reinstalling from generation..."
        _gen_path=$(nix-store -qR /nix/var/nix/profiles/nix-on-droid 2>/dev/null \
            | while read -r p; do case "$p" in *nix-on-droid-path) echo "$p";; esac; done)
        if [ -n "$_gen_path" ]; then
            nix profile install --profile "$_profile" "$_gen_path" 2>/dev/null || true
            log_success "Reinstalled nix-on-droid-path: $_gen_path"
        else
            log_error "Could not find nix-on-droid-path in system generation!"
        fi
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
    ./build.sh              Launch TUI menu
    ./build.sh <command>    Run command

${YELLOW}COMMANDS:${NC}
    switch      Apply home-manager config
    update      Update flake inputs
    show        Show flake outputs
    check       Validate flake
    status      System info
    clean       Garbage collect
    log         View build log

${YELLOW}EXAMPLES:${NC}
    ./build.sh switch       # Apply config
    ./build.sh update       # Update nixpkgs
    ./build.sh status       # Show installed packages
EOF
}

# ============================================================================
# MAIN
# ============================================================================

log "========== Build script started =========="

if [ $# -eq 0 ]; then
    run_tui
    exit 0
fi

case "$1" in
    -h|--help|help) show_help ;;
    switch)  cmd_switch ;;
    update)  cmd_update ;;
    show)    cmd_show ;;
    check)   cmd_check ;;
    status)  cmd_status ;;
    clean)   cmd_clean ;;
    log)     ${PAGER:-less} "$LOG_FILE" 2>/dev/null || log_info "No log file" ;;
    *)       log_error "Unknown: $1"; show_help; exit 1 ;;
esac

log "========== Build script finished =========="
