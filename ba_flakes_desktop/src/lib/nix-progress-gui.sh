#!/usr/bin/env bash
# nix-progress-gui.sh — KDE popup progress dialog for a running nix build.
#
# Tails a build log (as produced by build.sh's `tee -a "$LOG_FILE"`),
# classifies each line into a nix phase (eval / fetch / build / activate),
# and drives a kdialog --progressbar over DBus: phase label, a coarse
# percentage (phase weight + within-phase line count), and a live "verbose"
# line. kdialog's own Cancel button is polled; when pressed this script
# kills the caller-supplied PID's process GROUP (build.sh passes its own
# `$BASHPID` build subshell), so Cancel actually stops the build, not just
# the dialog.
#
# Usage: nix-progress-gui.sh <log_file> <build_pid> [title]
# Emits nothing to stdout; runs until the log file stops growing or the
# caller-supplied PID exits. Meant to be launched with `&` alongside the
# real build command, then `wait`ed / killed by the caller.
set -u

LOG_FILE="${1:?log file required}"
BUILD_PID="${2:?build pid required}"
TITLE="${3:-NixOS / Home Manager}"

command -v kdialog >/dev/null 2>&1 || exit 0   # headless / no KDE session — no-op

# Phase weights sum to 100; within a phase we creep the percentage toward
# the next phase's floor based on line volume, since nix gives no true ETA.
declare -A PHASE_FLOOR=( [eval]=0 [fetch]=15 [build]=35 [activate]=90 [done]=100 )
PHASE_ORDER=(eval fetch build activate done)

dbus_ref=$(kdialog --title "$TITLE" --progressbar "Starting…" 100) || exit 0
dbus_path="${dbus_ref%% *}"
dbus_service="${dbus_ref##* }"
# kdialog prints "SERVICE PATH" on one line separated by a space — normalize.
read -r dbus_service dbus_path <<<"$dbus_ref"

qd() { qdbus "$dbus_service" "$dbus_path" "$@" 2>/dev/null; }

phase="eval"
lines_in_phase=0
cancelled=0

classify() {
    case "$1" in
        *"evaluating"*|*"copying '<"*|*"fetching input"*) echo eval ;;
        *"copying path"*|*"fetching path"*|*"substituting"*) echo fetch ;;
        *"building '"*|*"Running phase"*) echo build ;;
        *"Activating "*|*"activation"*|*"home-manager switch"*) echo activate ;;
        *"Done."*|*"Total: switch"*) echo done ;;
        *) echo "" ;;
    esac
}

phase_pct() {
    local ph="$1" idx next floor nfloor
    for i in "${!PHASE_ORDER[@]}"; do
        [ "${PHASE_ORDER[$i]}" = "$ph" ] && idx=$i && break
    done
    floor=${PHASE_FLOOR[$ph]}
    nfloor=${PHASE_FLOOR[${PHASE_ORDER[$((idx+1))]:-done}]}
    # Creep up to 90% of the way to the next phase's floor based on volume
    # seen in this phase (capped — never let line-count alone reach nfloor,
    # so an actual phase transition is what finally crosses the boundary).
    local span=$(( nfloor - floor ))
    local creep=$(( lines_in_phase > 40 ? 36 : lines_in_phase ))
    echo $(( floor + span * creep / 40 * 90 / 100 ))
}

tail -n0 -F "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    kill -0 "$BUILD_PID" 2>/dev/null || break

    if [ "$(qd wasCancelled)" = "true" ]; then
        cancelled=1
        kill -TERM -- "-$(ps -o pgid= "$BUILD_PID" | tr -d ' ')" 2>/dev/null
        break
    fi

    np=$(classify "$line")
    if [ -n "$np" ] && [ "$np" != "$phase" ]; then
        phase="$np"
        lines_in_phase=0
    else
        lines_in_phase=$((lines_in_phase + 1))
    fi

    qd setLabelText "$(printf '[%s] %s' "$phase" "${line:0:120}")"
    qd Set "" value "$(phase_pct "$phase")"

    [ "$phase" = "done" ] && break
done

qd close 2>/dev/null || true
[ "$cancelled" = "1" ] && exit 130
exit 0
