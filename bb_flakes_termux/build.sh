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

# Ensure PATH includes nix profile + local bins (shell PATH may be broken)
export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Auto-confirm guardrail prompts — build.sh is the sanctioned interface
export BUILDSH_GUARDRAIL=1

# Verbosity: ON by default. Set QUIET=1 to silence (mostly useful for cron).
# When verbose, every command from the script body itself is also xtraced.
: "${VERBOSE:=1}"
: "${QUIET:=0}"
[ "$QUIET" = "1" ] && VERBOSE=0

# Verbose flags. `nix-on-droid` is a wrapper script that only accepts -h|--help
# — passing nix flags to it errors out instantly. Only the underlying `nix`
# / `nix build` / `nix flake` commands accept these.
NIX_VERBOSE_FLAGS=""
NIXOD_VERBOSE_FLAGS=""
if [ "$VERBOSE" = "1" ]; then
  NIX_VERBOSE_FLAGS="--show-trace --print-build-logs --verbose"
  # Nix-on-droid itself takes no flags; verbosity comes from underlying nix
  # via NIX_CONFIG env var (handled per-call where it matters).
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
LOG_FILE="$SCRIPT_DIR/build.log"

# Age key — dotfile symlink from vault/build.sh setup system, sops-nix fallback
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

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
# PERF — step timing library
# ============================================================================
# Uses epoch seconds (POSIX). Tracks per-step and total elapsed time.
#
#   perf_start "command-name"     — begin total timer, print header
#   perf_step  "step label"      — end previous step (if any), start new one
#   perf_end                     — end last step, print summary table
#
# Output example:
#   [PERF] ─ git stage .................. 0.2s
#   [PERF] ─ nix-on-droid switch ........ 47.3s
#   [PERF] ══ Total: switch ══════════ 48.1s

_PERF_CMD=""
_PERF_TOTAL_START=""
_PERF_STEP_START=""
_PERF_STEP_NAME=""
_PERF_STEPS=""      # newline-separated "seconds label" pairs

_epoch_ms() {
    # date +%s%N gives nanoseconds — divide by 1000000 for ms
    # Fall back to python3, then plain seconds
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import time; print(int(time.time()*1000))"
    elif date +%s%N >/dev/null 2>&1; then
        echo $(( $(date +%s%N) / 1000000 ))
    else
        echo "$(date +%s)000"
    fi
}

_fmt_duration() {
    # Input: milliseconds → output: human readable
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
    # Pad label with dots to fixed width
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
    # Close previous step
    if [ -n "$_PERF_STEP_START" ] && [ -n "$_PERF_STEP_NAME" ]; then
        _elapsed=$(( _now - _PERF_STEP_START ))
        _dur=$(_fmt_duration "$_elapsed")
        printf "${YELLOW}[PERF]${NC} ─ $(_perf_dots "$_PERF_STEP_NAME")${GREEN}%s${NC}\n" "$_dur"
        log "PERF: $_PERF_STEP_NAME = $_dur"
        _PERF_STEPS="${_PERF_STEPS}${_elapsed} ${_PERF_STEP_NAME}
"
    fi
    # Start new step
    _PERF_STEP_NAME="$1"
    _PERF_STEP_START=$(_epoch_ms)
}

perf_end() {
    _now=$(_epoch_ms)
    # Close last step
    if [ -n "$_PERF_STEP_START" ] && [ -n "$_PERF_STEP_NAME" ]; then
        _elapsed=$(( _now - _PERF_STEP_START ))
        _dur=$(_fmt_duration "$_elapsed")
        printf "${YELLOW}[PERF]${NC} ─ $(_perf_dots "$_PERF_STEP_NAME")${GREEN}%s${NC}\n" "$_dur"
        log "PERF: $_PERF_STEP_NAME = $_dur"
        _PERF_STEPS="${_PERF_STEPS}${_elapsed} ${_PERF_STEP_NAME}
"
    fi
    # Total
    _total=$(( _now - _PERF_TOTAL_START ))
    _total_dur=$(_fmt_duration "$_total")
    printf "${BOLD}${CYAN}[PERF]${NC} ${BOLD}══ Total: %s ══ %s${NC}\n" "$_PERF_CMD" "$_total_dur"
    log "PERF: TOTAL $_PERF_CMD = $_total_dur"
    # Reset
    _PERF_CMD=""
    _PERF_TOTAL_START=""
    _PERF_STEP_START=""
    _PERF_STEP_NAME=""
    _PERF_STEPS=""
}

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
    perf_start "switch"
    check_nix || return 1

    # Stage dirty files so nix flake evaluation sees changes
    perf_step "git stage"
    if command -v git >/dev/null 2>&1; then
        dirty=$(git -C "$SRC_DIR" status --porcelain 2>/dev/null || true)
        if [ -n "$dirty" ]; then
            log_info "Staging dirty files for flake evaluation..."
            git -C "$SRC_DIR" add -A 2>/dev/null || true
        fi
    fi

    # Clean old backup files
    perf_step "clean backups"
    backup_count=$(command find "$HOME" -maxdepth 1 -name "*.backup" -type f 2>/dev/null | wc -l)
    if [ "$backup_count" -gt 0 ]; then
        log_info "Cleaning $backup_count old backup file(s)..."
        command find "$HOME" -maxdepth 1 -name "*.backup" -type f -delete 2>/dev/null || true
    fi

    # Guard: profile must use nix-env format (manifest.nix), not nix profile
    # format (manifest.json). nix-on-droid's installPackages can't parse
    # nix profile list output from Nix 2.18+, causing duplicate entries.
    # If someone runs 'nix profile install', it converts the profile and breaks things.
    perf_step "profile guard"
    _profile="/nix/var/nix/profiles/per-user/nix-on-droid/profile"
    if [ -L "$_profile" ] && [ -f "$_profile/manifest.json" ]; then
        log_error "Profile uses 'nix profile' format (manifest.json) — incompatible with nix-on-droid"
        log_error "Use 'nix-env --profile $_profile -i <pkg>' instead of 'nix profile install'"
        perf_end
        return 1
    fi

    # Flake always wins: delete regular files where HM needs to place symlinks
    perf_step "clear stale files"
    for _hm_file in .claude/settings.json .claude/hooks/pretool-guard.sh .claude/skills/frontend-design.md .local/lib/httpd/github-markdown-dark.css .local/lib/httpd/marked.min.js .config/git/ignore .config/nix/nix.conf .ssh/authorized_keys .ssh/sshd_config .profile; do
        _full="$HOME/$_hm_file"
        if [ -f "$_full" ] && [ ! -L "$_full" ]; then
            rm -f "$_full"
        fi
    done

    perf_step "nix-on-droid switch"
    log_info "Applying nix-on-droid configuration (verbose=$VERBOSE)..."
    _rc_file=$(mktemp)
    _switch_log=$(mktemp)
    # tee to BOTH the log file AND the user's terminal — full visibility by
    # default. _switch_log captures the same output for the auto-medicine
    # scanner below. Verbose nix flags are appended for show-trace + build logs.
    { nix-on-droid switch --flake "$SRC_DIR" $NIXOD_VERBOSE_FLAGS 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE" "$_switch_log"
    exit_code=$(cat "$_rc_file" 2>/dev/null)
    exit_code=${exit_code:-0}
    rm -f "$_rc_file"

    # Auto-medicine: home-manager refuses to overwrite regular files that should
    # be symlinks ("Existing file 'X' is in the way"). Parse those paths, move
    # them to <path>.hm-conflict, retry once. Idempotent — only kicks in on a
    # very specific failure mode, no risk of clobbering anything else.
    if [ "$exit_code" -ne 0 ] && grep -q "is in the way of" "$_switch_log"; then
        log_warn "home-manager file conflict detected — applying auto-medicine"
        _moved=0
        while IFS= read -r _conflict; do
            # Match: "Existing file '/full/path' is in the way of '...'"
            _path=$(printf '%s\n' "$_conflict" | sed -n "s/.*Existing file '\([^']*\)' is in the way.*/\1/p")
            if [ -n "$_path" ] && [ -e "$_path" ] && [ ! -L "$_path" ]; then
                mv -f "$_path" "${_path}.hm-conflict.$(date +%s)"
                log_info "  moved: $_path -> ${_path}.hm-conflict.*"
                _moved=$((_moved + 1))
            fi
        done < "$_switch_log"
        if [ "$_moved" -gt 0 ]; then
            log_info "Retrying nix-on-droid switch after moving $_moved conflict(s)..."
            _rc_file=$(mktemp)
            { nix-on-droid switch --flake "$SRC_DIR" $NIXOD_VERBOSE_FLAGS 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
            exit_code=$(cat "$_rc_file" 2>/dev/null)
            exit_code=${exit_code:-0}
            rm -f "$_rc_file"
        fi
    fi
    rm -f "$_switch_log"

    if [ "$exit_code" -ne 0 ]; then
        log_error "Configuration failed (exit $exit_code)"
        log_info "Check $LOG_FILE for details"
        perf_end
        return "$exit_code"
    fi

    perf_end
    log_success "Configuration applied: $SRC_DIR"

    # Post-switch sanity check — data-driven from critical-commands.json.
    # Catches the case where home-manager activation reported success but a
    # silent `|| true` swallowed an npm/install failure (e.g. claude-code
    # SIGTERM'd by Android OOM).
    perf_step "post-switch verify"
    _verify_json="$SRC_DIR/modules/data/critical-commands.json"
    if [ -f "$_verify_json" ] && command -v jq >/dev/null 2>&1; then
        _missing=0
        _checked=0
        # Parse: name, path, fix from JSON. Expand $HOME at shell time.
        while IFS=$'\t' read -r _name _path _fix; do
            _checked=$((_checked + 1))
            _resolved=$(eval echo "$_path")
            if [ -e "$_resolved" ] || command -v "$_name" >/dev/null 2>&1; then
                continue
            fi
            _missing=$((_missing + 1))
            log_warn "MISSING: $_name (expected at $_resolved)"
            printf "         fix: %s\n" "$_fix"
        done <<EOT
$(jq -r '.commands[] | "\(.name)\t\(.path)\t\(.fix)"' "$_verify_json")
EOT
        if [ "$_missing" -eq 0 ]; then
            log_success "verify: all $_checked critical commands present"
        else
            log_warn "verify: $_missing/$_checked critical commands MISSING — see warnings above"
        fi
    else
        log_warn "verify: critical-commands.json or jq missing — skipping post-switch check"
    fi
    perf_end

    # Show cached drift summary (instant, no network)
    if command -v nix-drift >/dev/null 2>&1; then
        nix-drift drift --cached 2>/dev/null || true
        # Refresh cache in background for next switch
        nix-drift refresh &
    fi
}

cmd_update() {
    log_header "Updating Flake Inputs"
    check_nix || return 1

    cd "$SRC_DIR"
    log_info "Updating flake.lock..."

    _rc_file=$(mktemp)
    { nix flake update $NIX_VERBOSE_FLAGS 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
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
    { "$_nix" build "$SRC_DIR#nixOnDroidConfigurations.default.activationPackage" --impure --no-link $NIX_VERBOSE_FLAGS 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
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
    "$_nix" build "$SRC_DIR#nixOnDroidConfigurations.default.activationPackage" --impure --no-link --dry-run $NIX_VERBOSE_FLAGS 2>&1 | tee -a "$LOG_FILE"
}

cmd_check() {
    log_header "Flake Check"
    check_nix || return 1
    cd "$SRC_DIR"
    nix flake check
}

cmd_clean() {
    log_header "Cleaning"
    perf_start "clean"

    # Snapshot disk usage before
    _df_before=$(df -k /nix/store 2>/dev/null | awk 'NR==2{print $3}')
    log_info "Disk before: $(df -h /nix/store 2>/dev/null | awk 'NR==2{printf "%s used / %s avail", $3, $4}')"

    # 1. Remove result symlinks
    perf_step "remove symlinks"
    log_info "Removing result symlinks..."
    rm -f "$SRC_DIR/result" "$SRC_DIR/result-*"

    # 2. Trim home-manager generations (keep last 3)
    perf_step "trim hm generations"
    log_info "Trimming home-manager generations (keep last 3)..."
    nix-env --delete-generations +3 2>&1 || true

    # 3. Trim nix-on-droid profile generations (keep last 3)
    perf_step "trim nod generations"
    _profile="/nix/var/nix/profiles/per-user/nix-on-droid/profile"
    if [ -e "$_profile" ]; then
        log_info "Trimming nix-on-droid profile generations (keep last 3)..."
        nix-env --profile "$_profile" --delete-generations +3 2>&1 || true
    fi

    # 4. Garbage collect unreferenced store paths
    perf_step "nix-collect-garbage"
    log_info "Nix garbage collection..."
    nix-collect-garbage 2>&1 | tee -a "$LOG_FILE"

    # 5. Optimise store (deduplicate via hardlinks)
    perf_step "nix store optimise"
    log_info "Optimising nix store (dedup)..."
    nix store optimise 2>&1 | tee -a "$LOG_FILE"

    # 6. Clean nix eval/build caches
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

${YELLOW}ENV VARS:${NC}
    VERBOSE=1   (default) Pass --show-trace --print-build-logs --verbose to nix
    QUIET=1     Suppress verbose flags (sets VERBOSE=0)

${YELLOW}EXAMPLES:${NC}
    ./build.sh              # Apply config (same as switch), full nix output
    ./build.sh tui          # Interactive menu
    ./build.sh update       # Update nixpkgs (verbose)
    QUIET=1 ./build.sh      # Same but with minimal output (cron mode)
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
