#!/usr/bin/env bash
# nixos-switch-gui — kdialog progress window for NixOS build operations
# Placeholders replaced by package.nix substituteInPlace:
#   @DATA@     nixos-cp.json (nix store)
#   @JQ@       jq binary
#   @BASH@     bash binary
#   @KDIALOG@  kdialog binary
#   @QDBUS@    qdbus6 binary
set -euo pipefail

DATA="@DATA@"
JQ="@JQ@"
BASH="@BASH@"
KDIALOG="@KDIALOG@"
QDBUS="@QDBUS@"

FLAKE="$("$JQ" -r '.flake' "$DATA")"
CMD="${1:-switch}"

# --- X11 env (same discovery as tray.sh) ---
_rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -z "${DISPLAY:-}" ]; then
  for _n in 0 1 2; do [ -S "/tmp/.X11-unix/X${_n}" ] && export DISPLAY=":${_n}" && break; done
fi
if [ -z "${XAUTHORITY:-}" ]; then
  for _f in "${_rt}"/xauth_*; do [ -f "${_f}" ] && export XAUTHORITY="${_f}" && break; done
fi
unset WAYLAND_DISPLAY 2>/dev/null || true
export GDK_BACKEND=x11 NO_AT_BRIDGE=1
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${_rt}/bus}"

# Guard: if we are already inside a build, just exec it directly
if [ "${NIXOS_SWITCH_GUI_RUNNING:-}" = "1" ]; then
  exec "$BASH" -lc "cd '${FLAKE}' && PATH=/run/wrappers/bin:\$PATH ./build.sh '${CMD}'"
fi

LOG="${FLAKE}/logs/build-$(date +%Y%m%d-%H%M%S)-${CMD}.log"
mkdir -p "${FLAKE}/logs"

# Typical phase durations (seconds) — shown as estimates in the label
_EST=("~10s" "~60–180s" "~30s" "~10s" "")

# Phase labels (index = progress value 0-4)
PHASES=(
  "1/5 — Evaluating flake"
  "2/5 — Fetching / building derivations"
  "3/5 — Building system configuration"
  "4/5 — Activating configuration"
  "5/5 — Done"
)

# Start kdialog progress dialog (5 steps)
DLGSVC="$("$KDIALOG" --title "NixOS — ${CMD}" --progressbar "${PHASES[0]} (${_EST[0]})" 5 2>/dev/null)" || DLGSVC=""
DLGNAME="${DLGSVC%% *}"
DLGPATH="${DLGSVC##* }"

_set_label() {
  [ -z "$DLGNAME" ] && return 0
  "$QDBUS" "$DLGNAME" "$DLGPATH" setLabelText "$1" 2>/dev/null || true
}
_set_value() {
  [ -z "$DLGNAME" ] && return 0
  "$QDBUS" "$DLGNAME" "$DLGPATH" setValue "$1" 2>/dev/null || true
}
_close_dlg() {
  [ -z "$DLGNAME" ] && return 0
  "$QDBUS" "$DLGNAME" "$DLGPATH" close 2>/dev/null || true
}

_fmt_elapsed() {
  local s=$1
  if [ "$s" -ge 60 ]; then
    printf '%dm%02ds' $((s/60)) $((s%60))
  else
    printf '%ds' "$s"
  fi
}

# Run build in background, capturing all output to log
NIXOS_SWITCH_GUI_RUNNING=1 "$BASH" -lc \
  "cd '${FLAKE}' && PATH=/run/wrappers/bin:\$PATH ./build.sh '${CMD}'" \
  >"$LOG" 2>&1 &
BUILD_PID=$!
START_TIME=$(date +%s)

# Watch log and advance progress bar at recognised phase boundaries;
# update label every 2s with elapsed time + last meaningful log line.
PHASE=0
while kill -0 $BUILD_PID 2>/dev/null; do
  ELAPSED=$(( $(date +%s) - START_TIME ))
  EF="$(_fmt_elapsed "$ELAPSED")"

  if [ -f "$LOG" ]; then
    # Phase transitions
    if grep -qiE 'evaluating|fetching inputs' "$LOG" 2>/dev/null && [ $PHASE -lt 1 ]; then
      PHASE=1; _set_value 1
    fi
    if grep -qE '/nix/store.*\.drv|building path|copying path|these derivations' "$LOG" 2>/dev/null && [ $PHASE -lt 2 ]; then
      PHASE=2; _set_value 2
    fi
    if grep -qE 'activating|switching to system|running activation' "$LOG" 2>/dev/null && [ $PHASE -lt 3 ]; then
      PHASE=3; _set_value 3
    fi

    # Live label: phase title + elapsed + last log line (truncated)
    LAST="$(grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1 | cut -c1-90 || true)"
    EST="${_EST[$PHASE]:-}"
    if [ -n "$EST" ]; then
      LABEL="${PHASES[$PHASE]} (est. ${EST}) — ${EF} elapsed"$'\n'"${LAST}"
    else
      LABEL="${PHASES[$PHASE]} — ${EF} elapsed"$'\n'"${LAST}"
    fi
    _set_label "$LABEL"
  fi

  sleep 2
done

wait $BUILD_PID
EXIT_CODE=$?
TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))
TOTAL_FMT="$(_fmt_elapsed "$TOTAL_ELAPSED")"

_set_value 4
_set_label "5/5 — Done (${TOTAL_FMT} total)"
sleep 0.5
_close_dlg

if [ $EXIT_CODE -eq 0 ]; then
  "$KDIALOG" --title "NixOS — ${CMD}" --icon "dialog-ok" \
    --msgbox "Build complete: ${CMD}\nTotal time: ${TOTAL_FMT}\n\nLog: ${LOG}"
else
  TAIL="$(tail -20 "$LOG" 2>/dev/null || echo '(no output)')"
  "$KDIALOG" --title "NixOS — ${CMD}" --icon "dialog-error" \
    --error "Build failed (exit ${EXIT_CODE}) after ${TOTAL_FMT}\n\nLast output:\n${TAIL}\n\nFull log: ${LOG}"
fi
