#!/usr/bin/env bash
# system-protection-orphan-reaper.sh
#
# Find user-owned orphan processes (no tty, reparented to PID 1 or user
# systemd) that are NOT in the declarative whitelist, and either list them
# (--dry-run, default) or kill them (--apply).
#
# Whitelist source of truth: system-protection-orphan-reaper.json — same
# directory as this script when run from the repo, or $WHITELIST_JSON when
# invoked from a deployed location.
#
# Why this exists: a generic "kill every user process with no terminal whose
# parent is systemd" sweep WOULD work in theory, but in practice would also
# nuke half the KDE Plasma session (kwin, plasmashell, dbus, kwalletd, ...) —
# every one of those is reparented to user-systemd and has no controlling
# tty by design. The whitelist encodes "these are essential, never kill no
# matter what" so a dry-clean is safe to run any time without a restart.
#
# Defaults: dry-run, machine-readable summary at the end. Add --apply to
# actually send signals. --apply still uses TERM first, sleeps 0.3s, then
# KILL — matches the front/ engine's _kill_existing_watcher contract.
#
# Exit codes:
#   0  no kill candidates found (or all killed cleanly)
#   1  CLI / config error
#   2  some kills failed (apply mode only)

set -u
set -o pipefail

# ─── PATHS ─────────────────────────────────────────────────────
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHITELIST_JSON="${WHITELIST_JSON:-$SELF_DIR/system-protection-orphan-reaper.json}"

# ─── CLI ───────────────────────────────────────────────────────
MODE="dry-run"
VERBOSE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|--list)  MODE="dry-run"; shift ;;
        --apply|--kill)    MODE="apply"; shift ;;
        --verbose|-v)      VERBOSE=true; shift ;;
        --whitelist|-w)    WHITELIST_JSON="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: $(basename "$0") [--dry-run | --apply] [--verbose] [--whitelist PATH]

  --dry-run   (default) list kill candidates, do not signal
  --apply     send SIGTERM, sleep 0.3s, send SIGKILL to candidates
  --verbose   also print processes that were skipped (whitelisted)
  --whitelist override default whitelist JSON path

Whitelist: $WHITELIST_JSON
EOF
            exit 0
            ;;
        *)
            echo "✗ unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

[ -r "$WHITELIST_JSON" ] || { echo "✗ whitelist not readable: $WHITELIST_JSON" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq required" >&2; exit 1; }

# ─── LOAD WHITELIST INTO BASH ARRAYS ───────────────────────────
# Newline-separated to survive entries with spaces (we read with mapfile).
mapfile -t WL_COMM_EXACT      < <(jq -r '.comm_exact[]?'      "$WHITELIST_JSON")
mapfile -t WL_COMM_SUBSTR     < <(jq -r '.comm_substring[]?'  "$WHITELIST_JSON")
mapfile -t WL_EXE_SUBSTR      < <(jq -r '.exe_substring[]?'   "$WHITELIST_JSON")
mapfile -t WL_ARGV_SUBSTR     < <(jq -r '.argv_substring[]?'  "$WHITELIST_JSON")
mapfile -t WL_CGROUP_SUBSTR   < <(jq -r '.cgroup_substring[]?' "$WHITELIST_JSON")

# ─── DETECT USER + USER-SYSTEMD PID ────────────────────────────
USER_NAME="${USER:-$(id -un)}"
USER_UID="$(id -u)"
USER_SYSTEMD_PID="$(pgrep -u "$USER_NAME" -x systemd 2>/dev/null | head -1)"
USER_SYSTEMD_PID="${USER_SYSTEMD_PID:-0}"

# ─── HELPERS ───────────────────────────────────────────────────
# Returns 0 if $1 is in the whitelist (any rule matches), 1 otherwise.
# Side effect: sets MATCH_REASON to a short string for verbose output.
MATCH_REASON=""
is_whitelisted() {
    local comm="$1" exe="$2" argv="$3" cgroup="$4"
    local needle

    for needle in "${WL_COMM_EXACT[@]}"; do
        [ "$comm" = "$needle" ] && { MATCH_REASON="comm=$needle"; return 0; }
    done
    for needle in "${WL_COMM_SUBSTR[@]}"; do
        case "$comm" in *"$needle"*) MATCH_REASON="comm~$needle"; return 0 ;; esac
    done
    for needle in "${WL_EXE_SUBSTR[@]}"; do
        case "$exe" in *"$needle"*) MATCH_REASON="exe~$needle"; return 0 ;; esac
    done
    for needle in "${WL_ARGV_SUBSTR[@]}"; do
        case "$argv" in *"$needle"*) MATCH_REASON="argv~$needle"; return 0 ;; esac
    done
    for needle in "${WL_CGROUP_SUBSTR[@]}"; do
        case "$cgroup" in *"$needle"*) MATCH_REASON="cgroup~$needle"; return 0 ;; esac
    done
    MATCH_REASON=""
    return 1
}

# Returns 0 if $1 is a candidate user-orphan (reparented + no tty), else 1.
# Caller passes pid; this function reads /proc/$pid metadata.
is_user_orphan_candidate() {
    local pid="$1"
    [ -r "/proc/$pid/status" ] || return 1

    # Owner check: /proc/$pid is owned by Real UID
    local pid_uid
    pid_uid=$(awk '/^Uid:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null)
    [ "$pid_uid" = "$USER_UID" ] || return 1

    # Skip ourselves and our parent shell
    [ "$pid" = "$$" ] && return 1
    [ "$pid" = "$PPID" ] && return 1

    # ppid must be 1 OR user-systemd
    local ppid
    ppid=$(awk '/^PPid:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null)
    case "$ppid" in
        1|"$USER_SYSTEMD_PID") ;;
        *) return 1 ;;
    esac

    # Controlling tty must be 0 (none) — `ps` shows ? for this case
    local tty_nr
    tty_nr=$(awk '{print $7}' "/proc/$pid/stat" 2>/dev/null)
    [ "$tty_nr" = "0" ] || return 1

    return 0
}

# ─── SCAN ──────────────────────────────────────────────────────
KILL_PIDS=()
KILL_LINES=()
SKIP_LINES=()

for entry in /proc/[0-9]*; do
    pid="${entry#/proc/}"
    is_user_orphan_candidate "$pid" || continue

    # NEVER use `$(< file 2>/dev/null)` — bash's optimized `$(< file)` parser
    # silently returns empty when stderr redirection is appended (the
    # redirection breaks the special-case form). cat works reliably and
    # survives processes exiting mid-loop.
    comm=$(cat "/proc/$pid/comm" 2>/dev/null)
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null || echo "")
    argv=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    cgroup=$(cat "/proc/$pid/cgroup" 2>/dev/null)
    etime=$(ps -o etime= -p "$pid" 2>/dev/null | awk '{print $1}')
    pcpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | awk '{print $1}')

    if is_whitelisted "$comm" "$exe" "$argv" "$cgroup"; then
        SKIP_LINES+=("$(printf '%-7s %-7s %-6s %-20s %-30s %s' \
            "$pid" "$etime" "$pcpu" "$comm" "$MATCH_REASON" "${argv:0:60}")")
    else
        KILL_PIDS+=("$pid")
        KILL_LINES+=("$(printf '%-7s %-7s %-6s %-20s %-30s %s' \
            "$pid" "$etime" "$pcpu" "$comm" "${exe:-?}" "${argv:0:60}")")
    fi
done

# ─── REPORT ────────────────────────────────────────────────────
echo "orphan-reaper: user=$USER_NAME uid=$USER_UID user-systemd=$USER_SYSTEMD_PID"
echo "whitelist:    $WHITELIST_JSON"
echo "mode:         $MODE"
echo

if [ "$VERBOSE" = true ] && [ "${#SKIP_LINES[@]}" -gt 0 ]; then
    echo "── PROTECTED (whitelisted) — ${#SKIP_LINES[@]} ──"
    printf '%-7s %-7s %-6s %-20s %-30s %s\n' PID ETIME %CPU COMM REASON ARGV
    printf '%s\n' "${SKIP_LINES[@]}"
    echo
fi

if [ "${#KILL_LINES[@]}" -eq 0 ]; then
    echo "── no kill candidates ──"
    exit 0
fi

echo "── KILL CANDIDATES — ${#KILL_LINES[@]} ──"
printf '%-7s %-7s %-6s %-20s %-30s %s\n' PID ETIME %CPU COMM EXE ARGV
printf '%s\n' "${KILL_LINES[@]}"
echo

if [ "$MODE" = "dry-run" ]; then
    echo "(dry-run — re-run with --apply to actually kill)"
    exit 0
fi

# ─── APPLY ─────────────────────────────────────────────────────
echo "── applying SIGTERM ──"
# shellcheck disable=SC2068
kill ${KILL_PIDS[@]} 2>/dev/null || true
sleep 0.3
echo "── applying SIGKILL to survivors ──"
# shellcheck disable=SC2068
kill -9 ${KILL_PIDS[@]} 2>/dev/null || true
sleep 0.2

failed=0
for pid in "${KILL_PIDS[@]}"; do
    if [ -e "/proc/$pid" ]; then
        echo "  ✗ pid $pid survived"
        failed=$((failed + 1))
    fi
done

if [ "$failed" -gt 0 ]; then
    echo "── done: $((${#KILL_PIDS[@]} - failed))/${#KILL_PIDS[@]} reaped, $failed failed ──"
    exit 2
fi
echo "── done: all ${#KILL_PIDS[@]} reaped ──"
exit 0
