#!/usr/bin/env bash
# bash, not sh: the verify loop uses IFS=$'\t' (ANSI-C quoting) which
# dash parses as literal characters, silently mis-splitting every field
# (2026-08-08 audit).
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
NIX_CACHE_CFG="$SRC_DIR/modules/nix-cache.json"
# Output paths come from the ONE convention (1_cicd/src/scripts/
# cloud-data-paths.sh): logs/<name>.log · reports/<name>.json ·
# journal/<name>.text under cloud-data, with a $HOME fallback so a missing
# cloud-data clone can never kill the script (it used to die on line 1).
CLOUD_DATA_PATHS="$SCRIPT_DIR/../1_cicd/dist/scripts/cloud-data-paths.sh"
if [ -r "$CLOUD_DATA_PATHS" ]; then
    . "$CLOUD_DATA_PATHS"
    LOG_FILE="$(cd_log bb_flakes_termux)"
    ART_DIR="$(cd_artifact bb_flakes_termux)"
else
    LOG_FILE="$HOME/git/cloud-data/logs/bb_flakes_termux.log"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="$HOME/bb_flakes_termux.log"
    ART_DIR="$HOME/.cloud-data-artifacts/bb_flakes_termux"
fi

# Runtime artifacts (closures, OCI manifests, fetch plans) — cloud-data, never
# the repo: cmd_pull rm -rf's this dir and refills it from GHCR every run, so
# while it pointed at $SCRIPT_DIR/dist-ci a pull deleted its own tracked files.
# CI keeps writing in-tree because actions/upload-artifact only sees the
# workspace. TERMUX_ART_DIR overrides, for one-offs.
[ -n "${GITHUB_ACTIONS:-}" ] && ART_DIR="$SCRIPT_DIR/dist-ci"
[ -n "${TERMUX_ART_DIR:-}" ] && ART_DIR="$TERMUX_ART_DIR"
mkdir -p "$ART_DIR" 2>/dev/null || true

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

# publish_cloud_data_logs — commit + push this run's engine output to
# cloud-data. Runs at the END of every switch by design; the logs are
# useless sitting dirty in a clone nobody looks at. SWITCH_PUBLISH_LOGS=0
# skips it (cron/offline).
#
# NEVER fails the switch: an offline phone just leaves the commit local and
# the next switch carries it.
publish_cloud_data_logs() {
    if [ "${SWITCH_PUBLISH_LOGS:-1}" != "1" ]; then
        log_info "log publish: skipped (SWITCH_PUBLISH_LOGS=0)"
        return 0
    fi
    _cd="${CLOUD_DATA_ROOT:-$HOME/git/cloud-data}"
    if [ ! -d "$_cd/.git" ]; then
        log_warn "log publish: $_cd is not a git repo — logs stay local"
        return 0
    fi
    # Scope strictly to the three engine-output dirs. cloud-data holds other
    # generated content that is not this script's to commit.
    # Only dirs that CONTAIN something: git has no concept of an empty
    # directory, so passing one as a pathspec makes add/commit fail outright
    # ("did not match any files") — and it took the other paths down with it.
    _paths=""
    for _d in logs reports journal; do
        [ -d "$_cd/$_d" ] || continue
        [ -n "$(ls -A "$_cd/$_d" 2>/dev/null)" ] || continue
        _paths="$_paths $_d"
    done
    if [ -z "$_paths" ]; then
        log_info "log publish: no logs/reports/journal dirs yet"
        return 0
    fi
    # shellcheck disable=SC2086 — $_paths is an intentional word-split list
    if [ -z "$(git -C "$_cd" status --porcelain -- $_paths 2>/dev/null)" ]; then
        log_info "log publish: nothing changed"
        return 0
    fi
    # No `|| true` on these: swallowing the failure is exactly how the first
    # version of this function reported "pushed" while committing nothing.
    if ! git -C "$_cd" add -- $_paths 2>&1 | tee -a "$LOG_FILE"; then
        log_warn "log publish: git add failed — logs stay local"
        return 0
    fi
    if ! git -C "$_cd" commit -q \
            -m "logs: ${DTK_NODE_NAME:-$(hostname -s 2>/dev/null || echo device)} switch $(date -u +%FT%TZ)" \
            -- $_paths 2>&1 | tee -a "$LOG_FILE"; then
        log_warn "log publish: commit failed — logs staged but not committed"
        return 0
    fi
    # Push through the sync engine: another device may have pushed logs, and
    # the engine rebases (local wins) instead of failing on divergence. It
    # also marks itself active so cloud-data's pre-push hook cannot re-enter.
    _sync="$SCRIPT_DIR/../1_cicd/dist/scripts/cloud-git-sync.sh"
    if [ -x "$_sync" ]; then
        if ( cd "$_cd" && "$_sync" local -q ) >/dev/null 2>&1; then
            log_success "log publish: pushed to cloud-data"
        else
            log_warn "log publish: sync/push failed (offline?) — commit is local, next switch carries it"
        fi
    elif git -C "$_cd" push -q 2>/dev/null; then
        log_success "log publish: pushed to cloud-data"
    else
        log_warn "log publish: push failed (offline?) — commit is local, next switch carries it"
    fi
}

cmd_switch() {
    log_header "Switching to $SRC_DIR"
    perf_start "switch"
    check_nix || return 1

    # IDENTITY LINE — which tree is this switch actually building? Answers
    # "did my fixes land?" BEFORE the 10-minute build, not after (2026-08-08:
    # three switches in a row silently rebuilt a pre-fix tree because the
    # sync step had failed and nothing said so).
    if command -v git >/dev/null 2>&1; then
        _head=$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')
        _subj=$(git -C "$SRC_DIR" log -1 --format=%s 2>/dev/null | cut -c1-60)
        _dirtyn=$(git -C "$SRC_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        _behind=$(git -C "$SRC_DIR" rev-list --count "HEAD..origin/main" 2>/dev/null || echo '?')
        log_info "building: $_head \"$_subj\"  (dirty=$_dirtyn, behind origin/main=$_behind)"
        [ "$_behind" != "?" ] && [ "$_behind" -gt 0 ] 2>/dev/null && \
            log_warn "this tree is $_behind commit(s) BEHIND origin/main (last fetch) — run 'git sync' first if that's unexpected"
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

    # Vendor build.json into src/ so the path: flake reads it without a ../ ref
    # escaping src/ — any such escape forces nix to copy the whole 3.6GB repo as
    # the flake source and proot dies mid-copy ("Function not implemented").
    if [ -f "$SCRIPT_DIR/build.json" ]; then
        cp -f "$SCRIPT_DIR/build.json" "$SRC_DIR/build.json"
    fi

    # Prune old home-manager backups.
    #
    # NIX ALWAYS WINS is on (HOME_MANAGER_BACKUP_EXT, set before the switch
    # below): anything blocking a managed symlink is MOVED ASIDE, never left
    # to abort the switch. The extension must be timestamped — with a fixed
    # one, home-manager refuses to overwrite an existing backup and the
    # SECOND conflict on a file becomes fatal. Timestamps mean backups
    # accumulate forever unless something prunes them, which is this step.
    #
    # The old cleaner never deleted a single real backup (verified
    # 2026-08-09): it matched `*.backup` while home-manager writes
    # `*.hm-bak-<ts>`, used -maxdepth 1 while backups land under ~/.claude/
    # and ~/.config/, and used -type f while a backed-up directory (the
    # whole cloud-marketplace tree) is a dir.
    perf_step "clean backups"
    prune_hm_backups "${HM_BACKUP_RETENTION_DAYS:-7}"

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

    # Resolve any new flake inputs added to flake.nix but not yet in flake.lock.
    # nix flake lock with no --update-input only adds missing entries; existing
    # pins are untouched. This is the universal fix for "new input, stale lock".
    log_info "Locking any new flake inputs..."
    nix flake lock "path:$SRC_DIR" $NIX_VERBOSE_FLAGS 2>&1 | tee -a "$LOG_FILE" || true

    perf_step "nix-on-droid switch"
    log_info "Applying nix-on-droid configuration (verbose=$VERBOSE)..."
    # NIX ALWAYS WINS — home-manager's built-in conflict resolver. Any file
    # blocking a managed symlink is moved to <file>.hm-bak-<timestamp> and
    # the switch proceeds; without this the switch ABORTS with "Existing
    # file ... is in the way". No hardcoded per-file list needed. Identical
    # content is skipped (no backup churn). Pruned by "clean backups" above.
    export HOME_MANAGER_BACKUP_EXT="hm-bak-$(date +%Y%m%d-%H%M%S)"
    _rc_file=$(mktemp)
    # Capture THIS switch's output to a private file too — LOG_FILE accumulates
    # across runs, so grepping it for errors would match stale ones.
    _out_file=$(mktemp)
    { nix-on-droid switch --flake "path:$SRC_DIR" $NIXOD_VERBOSE_FLAGS 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE" "$_out_file"
    exit_code=$(cat "$_rc_file" 2>/dev/null)
    exit_code=${exit_code:-0}

    # False-green guard: `nix-on-droid switch` can exit 0 even when nix printed a
    # FATAL error (unfree-license refusal, missing attribute, SIGBUS during the
    # activation build). In that case the activation is never applied and NO new
    # generation is created, but the bare exit code lies and we'd report success.
    # A fatal nix error is a `^error:` line (col 0, no color when piped). The
    # benign flake-lock `error (ignored):` starts with "error " (space) not
    # "error:" so it does not match, and it is emitted before this block anyway.
    if grep -qE '^error:' "$_out_file"; then
        log_error "nix-on-droid printed a FATAL error (raw exit was $exit_code) — no generation applied:"
        grep -A6 -E '^error:' "$_out_file" | head -8 | while IFS= read -r _el; do log_error "  $_el"; done
        exit_code=1
    fi
    rm -f "$_rc_file" "$_out_file"

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
            # No eval (JSON-supplied data), no `command -v` fallback — the
            # fallback let stale imperative files in ~/.local/bin satisfy the
            # check, making the declared path unfalsifiable (2026-08-08 audit).
            _resolved=${_path//\$HOME/$HOME}
            if [ -e "$_resolved" ]; then
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

    # Fish command verify — every name declared in fish-commands.json must
    # actually RESOLVE in a real login fish. Declaring a command and having
    # it resolve are different things, and the gap has bitten twice:
    #   • `up` declared as a function while flake.nix ALSO defined it as an
    #     alias — the alias won and the function was dead (months).
    #   • a `functions -e up` de-shadow line erased the autoloaded function
    #     at init; fish then refuses to autoload it again for that session,
    #     so `up` became "Unknown command" (reproduced 2026-08-09).
    # Both were invisible to every other check. One `fish -c` covers all of
    # them from now on.
    _fish_json="$SRC_DIR/modules/data/fish-commands.json"
    if [ -f "$_fish_json" ] && command -v jq >/dev/null 2>&1 && command -v fish >/dev/null 2>&1; then
        _fnames=$(jq -r '(.abbrs[]?, .aliases[]?, .functions[]?) | select(.hidden != true) | .name' "$_fish_json")
        # -l: a LOGIN shell, so config.fish + interactiveShellInit run exactly
        # as they do for the user (that is where both bugs lived).
        _unresolved=$(printf '%s\n' "$_fnames" | fish -l -c '
            while read -l n
                test -n "$n"; or continue
                type -q -- $n; or abbr -q -- $n; or echo $n
            end' 2>/dev/null)
        _n_declared=$(printf '%s\n' "$_fnames" | grep -c . || true)
        if [ -n "$_unresolved" ]; then
            log_warn "verify: fish commands DECLARED but not resolving:"
            printf '%s\n' "$_unresolved" | while IFS= read -r _u; do
                [ -n "$_u" ] && printf "         %s\n" "$_u"
            done
            log_warn "         (shadowed by an alias, erased at init, or the function file did not deploy)"
        else
            log_success "verify: all $_n_declared fish commands resolve"
        fi
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
        _rescue="$HOME/git/cloud-mykonsole-dtk/5-infos/rescue-sshd/rescue-sshd.sh"
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
        log_error "  manual recovery on device: sh ~/git/cloud-mykonsole-dtk/5-infos/rescue-sshd/rescue-sshd.sh"
        log_error "  sshd log: $HOME/.cache/sshd.log"
    fi
    perf_end

    # Show cached drift summary (instant, no network) + tell the user the ONE
    # command that applies it. The list has been printed after every switch
    # for months with no actionable next step, so it just became wallpaper.
    if command -v nix-drift >/dev/null 2>&1; then
        _drift_out=$(nix-drift drift --cached 2>/dev/null || true)
        [ -n "$_drift_out" ] && printf '%s\n' "$_drift_out"
        _drift_n=$(printf '%s\n' "$_drift_out" | grep -cE '^[[:space:]]+[^[:space:]].*→' || true)
        if [ "${_drift_n:-0}" -gt 0 ]; then
            log_warn "$_drift_n update(s) pending — run './build.sh update' to apply ALL of them (versions+hashes → commit → sync → switch)"
        fi
        # Refresh cache in background for next switch
        ( flock -n 9 && nix-drift refresh ) 9>"$HOME/.cache/nix-drift.refresh.lock" 2>/dev/null &
    fi

    # LAST: ship this run's log. Anything logged after this line lands in the
    # next publish — unavoidable, since the log is still being written.
    perf_step "publish logs"
    publish_cloud_data_logs
    perf_end
}

# cmd_update — THE update path. Everything nix-drift reports, applied and
# shipped in one command:
#   1. nix-drift plan --apply   pinned versions + hashes + npm dep ranges
#   2. nix flake update         flake inputs (nixpkgs, home-manager, ...)
#   3. commit                   ONLY the files these two steps changed
#   4. git sync local           rebase (local wins) + push
#   5. switch                   build and activate
#
# It used to be step 2 alone — so `build.sh update` never moved a single
# pinned derivation, and the drift list just kept growing while the command
# named "update" reported success (2026-08-09).
#
# --no-switch stops after the push (useful from CI or when you want to switch
# later); --dry-run shows what would change and touches nothing.
cmd_update() {
    _no_switch=""; _dry=""
    for _a in "$@"; do
        case "$_a" in
            --no-switch) _no_switch=1 ;;
            --dry-run|-n) _dry=1 ;;
        esac
    done

    log_header "Update everything${_dry:+ (DRY RUN)}"
    perf_start "update"
    check_nix || return 1

    _repo="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
    if [ -z "$_repo" ]; then
        log_error "not inside a git repo — cannot update"
        perf_end; return 1
    fi

    # Snapshot the dirty set BEFORE, so step 3 commits only what the update
    # itself touched and never sweeps in unrelated work in progress.
    _before=$(mktemp); _after=$(mktemp)
    git -C "$_repo" status --porcelain 2>/dev/null | sort > "$_before"

    # ── 1. pinned versions + hashes ─────────────────────────────────
    perf_step "drift plan"
    if command -v nix-drift >/dev/null 2>&1; then
        if [ -n "$_dry" ]; then
            nix-drift plan 2>&1 | tee -a "$LOG_FILE" || true
        else
            nix-drift plan --apply 2>&1 | tee -a "$LOG_FILE" \
                || log_warn "nix-drift plan --apply reported errors — continuing"
        fi
    else
        log_warn "nix-drift not on PATH — skipping version/hash updates"
    fi

    # ── 2. flake inputs ─────────────────────────────────────────────
    perf_step "flake update"
    if [ -n "$_dry" ]; then
        log_info "would run: nix flake update (in $SRC_DIR)"
    else
        _rc_file=$(mktemp)
        { (cd "$SRC_DIR" && nix flake update $NIX_VERBOSE_FLAGS) 2>&1; echo $? > "$_rc_file"; } \
            | tee -a "$LOG_FILE"
        exit_code=$(cat "$_rc_file"); rm -f "$_rc_file"
        if [ "${exit_code:-1}" -ne 0 ]; then
            log_error "Flake update failed (exit $exit_code) — NOT committing or switching"
            rm -f "$_before" "$_after"; perf_end; return "$exit_code"
        fi
        log_success "flake inputs updated"
    fi

    # ── 3. commit exactly what changed ──────────────────────────────
    perf_step "commit"
    git -C "$_repo" status --porcelain 2>/dev/null | sort > "$_after"
    # Lines present after but not before = paths this update introduced or
    # whose status it changed. A file already dirty beforehand keeps its line
    # identical and is therefore left alone (your WIP is never swept in).
    _changed=$(comm -13 "$_before" "$_after" | sed 's/^...//')
    rm -f "$_before" "$_after"
    if [ -z "$_changed" ]; then
        log_info "nothing changed — already up to date"
    elif [ -n "$_dry" ]; then
        log_info "would commit:"; printf '%s\n' "$_changed" | sed 's/^/         /'
    else
        log_info "committing $(printf '%s\n' "$_changed" | grep -c .) changed file(s)"
        printf '%s\n' "$_changed" | while IFS= read -r _f; do
            [ -n "$_f" ] && git -C "$_repo" add -- "$_f" 2>/dev/null
        done
        git -C "$_repo" commit -q -m "chore(update): nix-drift versions/hashes + flake inputs

Applied by build.sh update on $(date -u +%FT%TZ)." \
            && log_success "committed" || log_warn "nothing to commit"
    fi

    # ── 4. sync (rebase local-wins + push) ──────────────────────────
    perf_step "git sync"
    _sync="$_repo/1_cicd/dist/scripts/cloud-git-sync.sh"
    if [ -n "$_dry" ]; then
        log_info "would run: git sync local"
    elif [ -x "$_sync" ]; then
        ( cd "$_repo" && "$_sync" local ) || log_warn "sync failed — continuing to switch with the local tree"
    else
        log_warn "sync engine not found at $_sync — skipping"
    fi

    perf_end

    # ── 5. switch ───────────────────────────────────────────────────
    if [ -n "$_dry" ]; then
        log_info "dry run complete — nothing was changed. Drop --dry-run to apply."
        return 0
    fi
    if [ -n "$_no_switch" ]; then
        log_success "update complete (--no-switch): run ./build.sh switch to activate"
        return 0
    fi
    cmd_switch
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

    # Vendor build.json into src/ so the path: flake reads it without a ../ ref
    # escaping src/ — any such escape forces nix to copy the whole 3.6GB repo as
    # the flake source and proot dies mid-copy ("Function not implemented").
    if [ -f "$SCRIPT_DIR/build.json" ]; then
        cp -f "$SCRIPT_DIR/build.json" "$SRC_DIR/build.json"
    fi

    log_info "Building activation package..."
    _nix="nix"
    [ -x "$HOME/.nix-profile/bin/nix" ] && _nix="$HOME/.nix-profile/bin/nix"
    _rc_file=$(mktemp)
    { "$_nix" build "path:$SRC_DIR#nixOnDroidConfigurations.default.activationPackage" --impure --no-link $NIX_VERBOSE_FLAGS 2>&1; echo $? > "$_rc_file"; } | tee -a "$LOG_FILE"
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

    # Vendor build.json into src/ so the path: flake reads it without a ../ ref
    # escaping src/ — any such escape forces nix to copy the whole 3.6GB repo as
    # the flake source and proot dies mid-copy ("Function not implemented").
    if [ -f "$SCRIPT_DIR/build.json" ]; then
        cp -f "$SCRIPT_DIR/build.json" "$SRC_DIR/build.json"
    fi

    log_info "Evaluating what would be built..."
    _nix="nix"
    [ -x "$HOME/.nix-profile/bin/nix" ] && _nix="$HOME/.nix-profile/bin/nix"
    "$_nix" build "path:$SRC_DIR#nixOnDroidConfigurations.default.activationPackage" --impure --no-link --dry-run $NIX_VERBOSE_FLAGS 2>&1 | tee -a "$LOG_FILE"
}

cmd_check() {
    log_header "Flake Check"
    check_nix || return 1
    cd "$SRC_DIR"
    nix flake check
}

# prune_hm_backups <retention_days> [--dry-run]
#
# Deletes home-manager conflict backups. Age 0 = purge EVERYTHING regardless
# of age (`-mtime +0` still means "older than 24h", so 0 has to bypass the
# age filter entirely — otherwise you can never clear today's backups, which
# is exactly the situation a broken pruner leaves you in).
#
# Matches BOTH `*.hm-bak-<ts>` (what home-manager writes) and the legacy
# `*.backup`, files AND directories, down to depth 4 — backups land in
# ~/.claude/, ~/.config/fish/, and a backed-up directory (the whole
# cloud-marketplace tree) is a dir, not a file.
prune_hm_backups() {
    _retain="${1:-7}"
    _dry=""
    [ "${2:-}" = "--dry-run" ] && _dry=1
    _baks=$(mktemp)
    # ~/git and friends pruned: home-manager never writes backups there and
    # walking the repos is slow on the phone.
    if [ "$_retain" = "0" ]; then
        _age=""
    else
        _age="-mtime +$_retain"
    fi
    # shellcheck disable=SC2086 — $_age is an intentional word-split flag pair
    command find "$HOME" -maxdepth 4 \
        \( -path "$HOME/git" -o -path "$HOME/.node_modules" -o -path "$HOME/storage" \
           -o -path "$HOME/Mounts" -o -path "$HOME/.cache" -o -path "$HOME/.local/state" \) -prune -o \
        \( -name '*.hm-bak-*' -o -name '*.backup' \) $_age -print \
        > "$_baks" 2>/dev/null || true
    _bak_n=$(wc -l < "$_baks" | tr -d ' ')
    if [ "${_bak_n:-0}" -eq 0 ]; then
        [ -n "$_dry" ] && log_info "No home-manager backups match (retention ${_retain}d)"
        rm -f "$_baks"
        return 0
    fi
    _bak_kb=$(while IFS= read -r _b; do du -sk "$_b" 2>/dev/null | cut -f1; done < "$_baks" \
              | awk '{s+=$1} END {print s+0}')
    if [ -n "$_dry" ]; then
        log_info "Would prune $_bak_n backup(s), ~$((_bak_kb / 1024))MB:"
        while IFS= read -r _b; do [ -n "$_b" ] && printf '    %s\n' "$_b"; done < "$_baks"
    else
        if [ "$_retain" = "0" ]; then
            log_info "Pruning ALL $_bak_n home-manager backup(s) (~$((_bak_kb / 1024))MB)"
        else
            log_info "Pruning $_bak_n home-manager backup(s) older than ${_retain}d (~$((_bak_kb / 1024))MB)"
        fi
        while IFS= read -r _b; do [ -n "$_b" ] && rm -rf "$_b"; done < "$_baks"
    fi
    rm -f "$_baks"
}

# clean-backups [days|all] [--dry-run] — standalone, no switch required.
cmd_clean_backups() {
    _arg="${1:-7}"
    case "$_arg" in
        all|ALL) _arg=0 ;;
        --dry-run) set -- 7 --dry-run; _arg=7 ;;
    esac
    log_header "Home-manager backup prune (retention: ${_arg}d)"
    prune_hm_backups "$_arg" "${2:-}"
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
    rm -f "$SRC_DIR/result" "$SRC_DIR"/result-*

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
# Per-path GHCR nix cache helpers + commands (incremental transport)
# ============================================================================

# _oras — oras CLI: available on PATH, or fall back to `nix run nixpkgs#oras`.
_oras() {
    if command -v oras >/dev/null 2>&1; then oras "$@"; return; fi
    # Prefer an already-realised store path (fast) over a fresh nix eval (slow
    # + fragile in proot). nix run re-evaluates nixpkgs every call.
    _o="$(ls -d /nix/store/*-oras-*/bin/oras 2>/dev/null | head -1)"
    if [ -n "$_o" ] && [ -x "$_o" ]; then "$_o" "$@"
    else nix run --extra-experimental-features "nix-command flakes" nixpkgs#oras -- "$@"; fi
}

# _zstd — zstd CLI: available on PATH, or fall back to `nix run nixpkgs#zstd`.
# zstd is NOT reliably on the nix-on-droid PATH.
_zstd() {
    if command -v zstd >/dev/null 2>&1; then zstd "$@"; return; fi
    _z="$(ls -d /nix/store/*-zstd-*/bin/zstd 2>/dev/null | head -1)"
    if [ -n "$_z" ] && [ -x "$_z" ]; then "$_z" "$@"
    else nix run --extra-experimental-features "nix-command flakes" nixpkgs#zstd -- "$@"; fi
}

# _closure_valid — true if $1 is in the store AND its whole closure is valid.
_closure_valid() {
    nix-store -qR "$1" >/dev/null 2>&1 || return 1
    [ -z "$(nix-store -qR "$1" 2>/dev/null | xargs -r nix-store --check-validity --print-invalid 2>/dev/null)" ]
}

# cmd_nixcache_publish — CI: export each custom store path as its own zstd blob
# and oras-push to GHCR. Content-addressed → GHCR dedups unchanged blobs so
# only changed paths actually upload (push delta).
cmd_nixcache_publish() {
    log_header "CI: publish per-path GHCR nix cache (oras)"
    [ -n "${GITHUB_TOKEN:-}" ] || { log_error "GITHUB_TOKEN required"; return 1; }
    command -v jq >/dev/null 2>&1 || { log_error "jq required"; return 1; }
    _cfg="$NIX_CACHE_CFG"
    [ "$(jq -r '.enabled' "$_cfg" 2>/dev/null)" = "true" ] || { log_warn "nix cache disabled"; return 0; }
    _ref="$(jq -r '.oci_ref' "$_cfg")"; _tag="$(jq -r '.oci_tag' "$_cfg")"
    _mtype="$(jq -r '.blob_media_type' "$_cfg")"; _tlann="$(jq -r '.toplevel_annotation' "$_cfg")"
    _manf="$(jq -r '.manifest_file' "$_cfg")"
    _out="$ART_DIR"
    _top="$(cat "$_out/activation.path" 2>/dev/null || true)"
    [ -n "$_top" ] && [ -d "$_top" ] || { log_error "no dist-ci/activation.path — run ci-build first"; return 1; }
    _tlname="$(basename "$_top")"; log_info "toplevel: $_tlname"

    # 1) topological order of the whole closure (deps BEFORE dependents).
    _work="$_out/nixcache"; rm -rf "$_work"; mkdir -p "$_work/blobs"
    for p in $(nix-store -qR "$_top"); do
        for r in $(nix-store -q --references "$p"); do
            [ "$r" = "$p" ] || printf '%s %s\n' "$r" "$p"
        done
        printf '%s %s\n' "$p" "$p"   # keep leaves (no refs) in the graph
    done | tsort > "$_work/topo.txt"

    # 2) custom = closure MINUS what cache.nixos.org OR nix-on-droid.cachix.org
    #    serves. A path is public if EITHER cache returns 200. Keep custom paths
    #    IN TOPOLOGICAL ORDER.
    nix-store -qR "$_top" | sort > "$_work/all.txt"
    log_info "probing public caches for $(wc -l < "$_work/all.txt") paths..."
    xargs -a "$_work/all.txt" -P 16 -I{} sh -c '
        h=$(basename "{}"); h=${h%%-*}
        curl -s -f -o /dev/null --retry 6 --retry-connrefused --retry-delay 1 \
          --max-time 40 "https://cache.nixos.org/${h}.narinfo" && echo "{}" && exit 0
        curl -s -f -o /dev/null --retry 6 --retry-connrefused --retry-delay 1 \
          --max-time 40 "https://nix-on-droid.cachix.org/${h}.narinfo" && echo "{}"
    ' | sort > "$_work/public.txt" || true
    comm -23 "$_work/all.txt" "$_work/public.txt" | sort > "$_work/custom-set.txt"
    { grep -Fx -f "$_work/custom-set.txt" "$_work/topo.txt" || true; } > "$_work/$_manf"   # topo-ordered custom
    _n=$(wc -l < "$_work/$_manf")
    log_info "custom paths: $_n of $(wc -l < "$_work/all.txt") (rest from public caches)"
    [ "$_n" -gt 0 ] || { log_warn "no custom paths — nothing to publish"; return 0; }

    # 3) export each custom path to its own zstd blob (filename = store hash).
    while IFS= read -r p; do
        h=$(basename "$p"); h=${h%%-*}
        nix-store --export "$p" | _zstd -T0 -19 -q -o "$_work/blobs/$h.zst"
    done < "$_work/$_manf"
    cp "$_work/$_manf" "$_work/blobs/$_manf"
    # Also ship the PUBLIC-deps list so the device can pre-substitute every
    # public-cache path BEFORE importing customs — then the topo-ordered
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

# nixcache_switch — device side: oras manifest fetch, pre-substitute public
# deps from BOTH caches, fetch only missing custom blobs, import in topo order.
# No sudo (nix-on-droid is single-user). Writes $_art/activation.name on success.
nixcache_switch() {
    _art="$1"
    command -v jq >/dev/null 2>&1 && [ -f "$NIX_CACHE_CFG" ] || return 1
    [ "$(jq -r '.enabled' "$NIX_CACHE_CFG" 2>/dev/null)" = "true" ] || return 1
    _ref="$(jq -r '.oci_ref' "$NIX_CACHE_CFG")"
    _tag="$(jq -r '.oci_tag' "$NIX_CACHE_CFG")"
    _ann="$(jq -r '.toplevel_annotation' "$NIX_CACHE_CFG")"
    _tok="$(gh auth token 2>/dev/null)" || return 1
    # GHCR login: username must be the package OWNER (derived from oci_ref).
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
    # VALIDITY check: a prior partial import can leave the dir present while
    # deps are invalid. --check-validity --recursive verifies the WHOLE closure.
    if _closure_valid "$_sys"; then
        log_success "nixcache: $_sysname closure already fully valid — no pull."; return 0
    fi

    # ── THE robust layered pull: no fragile per-error recovery. ──────────────
    # (0) pull two tiny index blobs: public.txt and topo-ordered custom list.
    # (A) pre-substitute ALL public deps from BOTH caches.
    # (B) fetch blobs for custom paths this device lacks or has corrupt.
    # (C) import customs IN TOPOLOGICAL ORDER — one pass, every ref valid.
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

    # (A) pre-substitute all public deps. Use `nix-store --realise`, NOT
    #     `nix copy --from <single-source>`: public.txt mixes paths that live on
    #     DIFFERENT caches (cache.nixos.org vs nix-on-droid.cachix.org). A
    #     batched `nix copy --from cache.nixos.org` errors + skips the rest of
    #     its batch the moment it hits a cachix-only path (e.g. *-android
    #     static libs), leaving public refs invalid → custom imports then fail.
    #     `nix-store -r` consults ALL configured substituters at once (both
    #     caches, both trusted keys) and only fetches what's missing.
    log_info "nixcache: pre-substituting $(wc -l < "$_art/public.txt") public deps (all configured caches) ..."
    xargs -a "$_art/public.txt" -r nix-store --realise 2>&1 | tail -3 || true

    # (B) which custom paths must we fetch? missing dirs + present-but-INVALID.
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
    #     Single-user nix-on-droid: no sudo.
    log_info "nixcache: importing custom paths in topological order ..."
    while IFS= read -r _p; do
        _ph="$(basename "$_p")"; h="${_ph%%-*}"; f="$_bd/${h}.zst"
        [ -e "$f" ] || continue
        if _zstd -dq -c "$f" | nix-store --import >/dev/null 2>"$f.err"; then
            log "  imported $_ph"
        else
            log_warn "  import failed $_ph: $(tail -1 "$f.err" 2>/dev/null)"
        fi
        rm -f "$f" "$f.err"
    done < "$_art/custom-topo.txt"

    if _closure_valid "$_sys"; then
        rm -rf "$_bd"
        log_success "nixcache: closure fully valid (GHCR per-path delta — no 2.2GB pull; pre-filled public + topo import)."
        return 0
    fi
    log_warn "nixcache: $_sys still missing after import — falling back."
    return 1
}

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
    _out="$ART_DIR"
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

    # Vendor build.json into src/ so the path: flake reads it without a ../ ref
    # escaping src/ — any such escape forces nix to copy the whole 3.6GB repo as
    # the flake source and proot dies mid-copy ("Function not implemented").
    # cmd_switch and cmd_build both do this; ci-build did not, so every CI run
    # died at eval with "opening file '.../source/build.json': No such file".
    # src/build.json is gitignored, so the checkout never carries it.
    if [ -f "$SCRIPT_DIR/build.json" ]; then
        cp -f "$SCRIPT_DIR/build.json" "$SRC_DIR/build.json"
    fi

    log_info "Building activationPackage (accept-flake-config → cached substitutes)..."
    "$_nix" build "path:$SRC_DIR#nixOnDroidConfigurations.default.activationPackage" \
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

    # ── Stage 1: per-path GHCR nix cache (TRUE incremental delivery) ────────
    # Additive + non-fatal: the nar.zst above stays a fallback. Publishes each
    # custom store path as its own oras blob so `cmd_pull` fetches only the delta.
    if [ "${GHCR_PUSH:-0}" = "1" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
        cmd_nixcache_publish || log_warn "nixcache publish failed (non-fatal — nar.zst artifact still delivered)"
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
# PRIMARY path: per-path GHCR nix cache (oras, delta-only, no 2.2GB image).
# FALLBACK: local nar.zst tarball (only if already downloaded).
# ghcr_pull_layered_skopeo is NEVER called automatically (downloads 2.2GB on
# mobile data — user directive: do not auto-pull the full image).
cmd_pull() {
    log_header "Activate prebuilt closure (no eval — cannot OOM the phone)"
    check_nix || return 1
    _art="${1:-$ART_DIR}"
    _tb="$_art/nixondroid-closure.nar.zst"
    _sys=""

    # ── PRIMARY: per-path GHCR nix cache (TRUE incremental, KB manifest) ──
    if nixcache_switch "$_art"; then
        _sys="/nix/store/$(cat "$_art/activation.name" 2>/dev/null)"
        [ -d "$_sys" ] || { log_warn "nixcache_switch succeeded but $_sys missing — trying fallback"; _sys=""; }
    fi

    # ── FALLBACK 1: local nar.zst tarball (must already be present) ──────
    if [ -z "$_sys" ] || [ ! -d "$_sys" ]; then
        if [ -f "$_tb" ] && [ -f "$_art/activation.name" ]; then
            _sys="/nix/store/$(cat "$_art/activation.name")"
            log_info "Importing closure from local nar.zst (no build)..."
            _zstd -d -c "$_tb" | nix-store --import >/dev/null || _sys=""
        fi
    fi

    # ── FALLBACK 2: nix-on-droid switch --flake (uses already-realised store
    #    paths — no eval OOM, no network download, pure local activation).
    #    This is the ultimate fallback when GHCR is unreachable (e.g. IPv6-only
    #    network) and no local tarball exists. Nix must always win.
    if [ -z "$_sys" ] || [ ! -d "$_sys" ]; then
        log_warn "GHCR and tarball unavailable — falling back to nix-on-droid switch (local store)"
        nix-on-droid switch --flake "path:$SRC_DIR#default" \
            || { log_error "nix-on-droid switch also failed; you may need network for new paths"; return 1; }
        log_success "Activated via nix-on-droid switch (local store fallback)."
        return 0
    fi
    [ -d "$_sys" ] || { log_error "activation path $_sys missing after import"; return 1; }

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
    update      Update EVERYTHING: pinned versions+hashes (nix-drift) + flake
                inputs, commit just those files, git sync, then switch.
                --dry-run to preview, --no-switch to stop after the push.
    clean       Garbage collect
    clean-backups [days|all] [--dry-run]
                Prune home-manager conflict backups (*.hm-bak-*). Default 7
                days; `all` purges every one. Runs automatically each switch.
    log         View build log

${YELLOW}ENV VARS:${NC}
    VERBOSE=1   (default) Pass --show-trace --print-build-logs --verbose to nix
    QUIET=1     Suppress verbose flags (sets VERBOSE=0)

${YELLOW}EXAMPLES:${NC}
    ./build.sh              # Apply config (same as switch), full nix output
    ./build.sh tui          # Interactive menu
    ./build.sh update       # Update nixpkgs (verbose)
    QUIET=1 ./build.sh      # Same but with minimal output (cron mode)
    ./build.sh clean-backups all --dry-run   # what would be purged
    ./build.sh clean-backups all             # purge every hm-bak backup now
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
    nixcache-publish) cmd_nixcache_publish ;;
    pull|switch-remote) cmd_pull "${2:-}" ;;
    dry-run|plan) cmd_dry_run ;;
    tui)     run_tui ;;
    update)  shift; cmd_update "$@" ;;
    show)    cmd_show ;;
    check)   cmd_check ;;
    status)  cmd_status ;;
    clean)   cmd_clean ;;
    clean-backups) cmd_clean_backups "${2:-}" "${3:-}" ;;
    log)     ${PAGER:-less} "$LOG_FILE" 2>/dev/null || log_info "No log file" ;;
    *)       log_error "Unknown: $1"; show_help; exit 1 ;;
esac

log "========== Build script finished =========="
