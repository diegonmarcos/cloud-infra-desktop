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
        _PERF_STEP_START=""
        _PERF_STEP_NAME=""
    fi
    # Total — only when a total timer is actually active. perf_end may be
    # called again for post-switch addendum steps (verify, sshd-guarantee)
    # after the main perf_end already reset the timer; without this guard
    # `_now - ""` prints the full epoch as minutes (the 29726296m bug).
    if [ -n "$_PERF_TOTAL_START" ]; then
        _total=$(( _now - _PERF_TOTAL_START ))
        _total_dur=$(_fmt_duration "$_total")
        printf "${BOLD}${CYAN}[PERF]${NC} ${BOLD}══ Total: %s ══ %s${NC}\n" "$_PERF_CMD" "$_total_dur"
        log "PERF: TOTAL $_PERF_CMD = $_total_dur"
    fi
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

    perf_step "nix-on-droid switch"
    log_info "Applying nix-on-droid configuration (verbose=$VERBOSE)..."
    # HOME_MANAGER_BACKUP_EXT: home-manager's built-in conflict resolver — any
    # plain file blocking a managed symlink is moved to <file>.hm-conflict
    # automatically. Nix always wins; no hardcoded per-file list needed.
    export HOME_MANAGER_BACKUP_EXT="hm-bak-$(date +%Y%m%d-%H%M%S)"
    _rc_file=$(mktemp)
    { nix-on-droid switch --flake "$SRC_DIR" $NIXOD_VERBOSE_FLAGS 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
    exit_code=$(cat "$_rc_file" 2>/dev/null)
    exit_code=${exit_code:-0}
    rm -f "$_rc_file"

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

    # ────────────────────────────────────────────────────────────────────
    # Mandatory post-switch sshd guarantee: every successful switch MUST
    # leave sshd up, OR loudly tell the user it's broken AND how to recover.
    # No more "config applied" with sshd silently dead.
    # ────────────────────────────────────────────────────────────────────
    perf_step "sshd guarantee"
    _wg_ip=$(awk -F'"' '/"wg_ip"/{print $4; exit}' "$SCRIPT_DIR/build.json" 2>/dev/null)
    _wg_ip="${_wg_ip:-127.0.0.1}"
    # ssh_port is an unquoted JSON number ("ssh_port": 8024) — split on : and ,
    # then strip non-digits. Data-driven from build.json; never hardcode.
    _ssh_port=$(awk -F'[:,]' '/"ssh_port"/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$SCRIPT_DIR/build.json" 2>/dev/null)
    _ssh_port="${_ssh_port:-8024}"
    _sshd_up=0

    # Path 1: the flake-deployed wrapper (uses opensshPinned + sshd_config).
    if [ -x "$HOME/.local/bin/cloud-ide-sshd" ]; then
        log_info "sshd-guarantee: (1/2) trying flake wrapper restart..."
        if "$HOME/.local/bin/cloud-ide-sshd" restart 2>&1 | tee -a "$LOG_FILE"; then
            sleep 1
            if [ -f "$HOME/.cache/sshd.pid" ] && kill -0 "$(cat "$HOME/.cache/sshd.pid")" 2>/dev/null; then
                _sshd_up=1
            fi
        fi
    fi

    # Path 2: independent rescue script (uses ~/.nix-profile/bin/sshd directly,
    # not whatever the flake wrapper happens to point at). Last-resort.
    if [ "$_sshd_up" -eq 0 ]; then
        log_warn "sshd-guarantee: wrapper path failed, falling back to rescue-sshd..."
        _rescue="$HOME/git/tools/5-infos/rescue-sshd/rescue-sshd.sh"
        if [ -x "$_rescue" ] || [ -f "$_rescue" ]; then
            sh "$_rescue" 2>&1 | tee -a "$LOG_FILE"
            sleep 1
            if [ -f "$HOME/.cache/sshd.pid" ] && kill -0 "$(cat "$HOME/.cache/sshd.pid")" 2>/dev/null; then
                _sshd_up=1
            fi
        else
            log_error "sshd-guarantee: $_rescue not found"
        fi
    fi

    # Verify TCP listen actually accepts on :$_ssh_port (Android `ss` output is
    # spotty — try ss first, fall back to nc against the WG IP and 127.0.0.1).
    _bound=0
    if ss -tln 2>/dev/null | grep -q ":$_ssh_port "; then _bound=1; fi
    [ "$_bound" -eq 0 ] && nc -z -w 2 "$_wg_ip" "$_ssh_port" 2>/dev/null && _bound=1
    [ "$_bound" -eq 0 ] && nc -z -w 2 127.0.0.1 "$_ssh_port" 2>/dev/null && _bound=1

    if [ "$_sshd_up" -eq 1 ] && [ "$_bound" -eq 1 ]; then
        log_success "sshd-guarantee: listening on :$_ssh_port (WG=$_wg_ip)"
    elif [ "$_sshd_up" -eq 1 ]; then
        log_warn "sshd-guarantee: process up but port :$_ssh_port not detected — verify manually"
    else
        log_error "sshd-guarantee: BOTH wrapper AND rescue failed. SSH UNAVAILABLE."
        log_error "  manual recovery on device: sh ~/git/tools/5-infos/rescue-sshd/rescue-sshd.sh"
        log_error "  sshd log: $HOME/.cache/sshd.log"
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

    # 3. Trim nix-on-droid per-user sub-profile generations (keep last 3)
    perf_step "trim nod sub generations"
    _profile="/nix/var/nix/profiles/per-user/nix-on-droid/profile"
    if [ -e "$_profile" ]; then
        log_info "Trimming nix-on-droid per-user sub-profile generations (keep last 3)..."
        nix-env --profile "$_profile" --delete-generations +3 2>&1 || true
    fi

    # 3b. Trim top-level nix-on-droid profile generations (keep last 3)
    # Each `nix-on-droid switch` adds a generation here; on long-lived devices
    # this is the dominant store-pinning GC root (hundreds of full closures).
    perf_step "trim nod top generations"
    _profile_top="/nix/var/nix/profiles/nix-on-droid"
    if [ -e "$_profile_top" ]; then
        log_info "Trimming top-level nix-on-droid profile generations (keep last 3)..."
        nix-env --profile "$_profile_top" --delete-generations +3 2>&1 || true
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
# REMOTE BUILD (GHA arm64) + LOCAL ACTIVATE — never OOM the phone with an eval
# ============================================================================
# The phone (7GB, proot) OOM-thrashes on a local `nix-on-droid switch`. So the
# aarch64 eval+build runs on a GitHub arm64 runner (`ci-build`), and the phone
# only IMPORTS the prebuilt closure + runs its activate script (`pull`) — no
# eval, no compile → cannot OOM.

# ci-build — run on a GHA ubuntu-24.04-arm runner. Build the nix-on-droid
# activationPackage and export its closure as a zstd tarball into dist-ci/.
cmd_ci_build() {
    log_header "CI: build + export nix-on-droid closure (aarch64)"
    check_nix || return 1
    _out="$SCRIPT_DIR/dist-ci"
    rm -rf "$_out"; mkdir -p "$_out"

    # Free GHA-runner disk — the closure + export won't fit in the default root.
    # Only touch the runner's preinstalled bloat, never a real system.
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        log_info "Freeing GHA runner disk..."
        sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
                    /opt/hostedtoolcache/CodeQL /usr/local/share/boost 2>/dev/null || true
    fi

    _nix="nix"; [ -x "$HOME/.nix-profile/bin/nix" ] && _nix="$HOME/.nix-profile/bin/nix"

    # builtins.storePath checks the LOCAL nix store at eval time — substituters
    # are NOT consulted during evaluation. Pre-copy proot-termux-static from the
    # nix-on-droid cachix so the path exists before nix build starts evaluating.
    # ponytail: hardcoded path matches flake.lock nix-on-droid pin; update when bumping.
    _PROOT="/nix/store/7qd99m1w65x2vgqg453nd70y60sm3kay-proot-termux-static-aarch64-unknown-linux-android-unstable-2024-05-04"
    if ! nix-store --check-validity "$_PROOT" 2>/dev/null; then
        log_info "Pre-fetching proot-termux-static (builtins.storePath needs local presence at eval time)..."
        "$_nix" copy --from "https://nix-on-droid.cachix.org" --no-check-sigs \
            --extra-experimental-features "nix-command flakes" \
            "$_PROOT" 2>&1 || log_warn "proot pre-fetch failed — nix build may error at eval"
    fi

    log_info "Building activationPackage (accept-flake-config → cached substitutes)..."
    "$_nix" build "$SRC_DIR#nixOnDroidConfigurations.default.activationPackage" \
        --impure --accept-flake-config --out-link "$_out/result" \
        --extra-experimental-features "nix-command flakes" $NIX_VERBOSE_FLAGS \
        || { log_error "ci build failed"; return 1; }

    _sys=$(readlink -f "$_out/result")
    basename "$_sys" > "$_out/activation.name"
    echo "$_sys" > "$_out/activation.path"
    log_info "Exporting closure -> zstd tarball..."
    nix-store --export $(nix-store -qR "$_sys") | zstd -T0 -15 > "$_out/nixondroid-closure.nar.zst"
    rm -f "$_out/result"
    log_success "Done: $(du -h "$_out/nixondroid-closure.nar.zst" | cut -f1) -> $_out/"

    # ── Stage 1: layered GHCR cache (INCREMENTAL delivery) ──────────────────
    # Additive + NON-FATAL: the nar.zst above stays the active mechanism until
    # `cmd_pull` learns to consume this. Mirrors ba_flakes_desktop's
    # cmd_ci_build exactly. Guarded by GHCR_PUSH=1.
    if [ "${GHCR_PUSH:-0}" = "1" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
        _img="${TERMUX_CACHE_IMAGE:-ghcr.io/diegonmarcos/unix-termux-cache}"
        log_info "building + pushing layered termux cache image -> ${_img}:latest (incremental)"
        # GHA Ubuntu runners ship /etc/containers/registries.conf as legacy v1,
        # which skopeo 1.23 refuses ("must be in v2 format"). Empty v2 config —
        # fully-qualified refs need no registries. (2026-07-09 silent-push fix.)
        local _reg="$_out/registries.conf"
        printf 'unqualified-search-registries = []\n' > "$_reg"
        if "$_nix" build "$SRC_DIR#packages.aarch64-linux.termux-cache-image" \
             --impure --accept-flake-config --out-link "$_out/termux-cache-image" \
             --extra-experimental-features "nix-command flakes"; then
            CONTAINERS_REGISTRIES_CONF="$_reg" \
            "$_nix" run --extra-experimental-features "nix-command flakes" nixpkgs#skopeo -- \
                copy --dest-creds "x:${GITHUB_TOKEN}" \
                "docker-archive:$(readlink -f "$_out/termux-cache-image")" \
                "docker://${_img}:latest" \
                && log_success "pushed layered termux cache -> ${_img}:latest" \
                || log_warn "skopeo push failed (non-fatal — nar.zst artifact still delivered)"
        else
            log_warn "termux-cache-image build failed (non-fatal — nar.zst still delivered)"
        fi
        rm -f "$_out/termux-cache-image"
    fi
}

# ghcr_pull_layered_skopeo <image:tag> — materialise a layered GHCR closure
# image's /nix/store paths onto the local store WITHOUT a Docker daemon
# (Android/Termux has none). skopeo's `dir:` transport just downloads the
# manifest + blob files to a plain directory — no daemon required, and it
# already skips blobs it can prove are unchanged. Each blob is a tar rooted
# at `/` (dockerTools.buildLayeredImage convention: `nix/store/...` with no
# leading slash), so `tar --skip-old-files` extracting straight onto `/`
# gives genuine incremental behaviour: paths already on the phone are never
# rewritten. Returns 1 on ANY failure — additive, caller falls back to
# nar.zst.
ghcr_pull_layered_skopeo() {
    _img="$1"
    _nix_bin="nix"; [ -x "$HOME/.nix-profile/bin/nix" ] && _nix_bin="$HOME/.nix-profile/bin/nix"
    command -v "$_nix_bin" >/dev/null 2>&1 || return 1
    _tmpdir=$(mktemp -d)
    log_info "Trying layered GHCR pull (skopeo, no daemon): $_img ..."
    "$_nix_bin" run --extra-experimental-features "nix-command flakes" nixpkgs#skopeo -- \
        copy "docker://$_img" "dir:$_tmpdir" >/dev/null 2>&1 \
        || { log_warn "GHCR image unavailable — falling back to nar.zst"; rm -rf "$_tmpdir"; return 1; }

    _extracted=0
    for _blob in "$_tmpdir"/*; do
        case "$(basename "$_blob")" in
            manifest.json|version) continue ;;
        esac
        tar -x --skip-old-files -f "$_blob" -C / 2>/dev/null && _extracted=$((_extracted + 1))
    done
    rm -rf "$_tmpdir"
    log_success "Layered pull: $_extracted layer(s) extracted (unchanged store paths skipped)"
    [ "$_extracted" -gt 0 ]
}

# pull [artifact-dir] — run on the phone. Import a GHA-built closure and run its
# activate script. NO eval, NO build -> cannot OOM. Default dir is dist-ci/
# (e.g. after: gh run download -n nixos-termux-closure -D dist-ci).
cmd_pull() {
    log_header "Activate prebuilt closure (no eval — cannot OOM the phone)"
    check_nix || return 1
    _art="${1:-$SCRIPT_DIR/dist-ci}"
    _tb="$_art/nixondroid-closure.nar.zst"
    _sys=""
    [ -f "$_art/activation.name" ] && _sys="/nix/store/$(cat "$_art/activation.name")"

    # ── Try GHCR-layered pull first (incremental, no Docker daemon) ──────
    _img="${TERMUX_CACHE_IMAGE:-ghcr.io/diegonmarcos/unix-termux-cache}:latest"
    if [ -n "$_sys" ] && [ -d "$_sys" ]; then
        log_info "$_sys already present locally — skipping pull entirely."
    elif ghcr_pull_layered_skopeo "$_img" && [ -n "$_sys" ] && [ -d "$_sys" ]; then
        log_success "Activation closure materialised via layered GHCR pull."
    else
        [ -f "$_tb" ] || { log_error "no closure tarball at $_tb (fetch: gh run download -n nixos-termux-closure -D '$_art')"; return 1; }
        [ -f "$_art/activation.name" ] || { log_error "missing $_art/activation.name"; return 1; }
        _sys="/nix/store/$(cat "$_art/activation.name")"

        log_info "Importing closure into the store (no build)..."
        zstd -d -c "$_tb" | nix-store --import >/dev/null || { log_error "import failed"; return 1; }
    fi
    [ -d "$_sys" ] || { log_error "imported path $_sys missing after import"; return 1; }

    # nix-on-droid activationPackages expose the activator at ./activate
    # (older layouts at ./bin/activate) — prefer whichever exists.
    _act="$_sys/activate"; [ -x "$_act" ] || _act="$_sys/bin/activate"
    [ -x "$_act" ] || { log_error "no activate script in $_sys"; return 1; }
    log_info "Activating ($_act)..."
    "$_act"
    log_success "Activated prebuilt generation (no eval)."
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
    ci-build    [GHA arm64] Build + export the closure tarball -> dist-ci/
    pull [dir]  Import a GHA-built closure + activate (NO eval — never OOMs)
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
    ci-build) cmd_ci_build ;;
    pull|switch-remote) cmd_pull "$2" ;;
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
