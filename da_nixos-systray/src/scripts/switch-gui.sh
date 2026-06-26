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

# Phase labels (index = progress value 0-4)
PHASES=(
  "1/5 — Evaluating flake…"
  "2/5 — Fetching / building derivations…"
  "3/5 — Building system configuration…"
  "4/5 — Activating configuration…"
  "5/5 — Done"
)

# Start kdialog progress dialog (5 steps)
DLGSVC="$("$KDIALOG" --title "NixOS — ${CMD}" --progressbar "${PHASES[0]}" 5 2>/dev/null)" || DLGSVC=""
DLGNAME="${DLGSVC%% *}"
DLGPATH="${DLGSVC##* }"

_progress() {
  local step="$1"
  [ -z "$DLGNAME" ] && return 0
  "$QDBUS" "$DLGNAME" "$DLGPATH" setValue  "$step"           2>/dev/null || true
  "$QDBUS" "$DLGNAME" "$DLGPATH" setLabelText "${PHASES[$step]}" 2>/dev/null || true
}
_close_dlg() {
  [ -z "$DLGNAME" ] && return 0
  "$QDBUS" "$DLGNAME" "$DLGPATH" close 2>/dev/null || true
}

# Run build in background, capturing all output to log
NIXOS_SWITCH_GUI_RUNNING=1 "$BASH" -lc \
  "cd '${FLAKE}' && PATH=/run/wrappers/bin:\$PATH ./build.sh '${CMD}'" \
  >"$LOG" 2>&1 &
BUILD_PID=$!

# Watch log and advance progress bar at recognised phase boundaries
PHASE=0
while kill -0 $BUILD_PID 2>/dev/null; do
  if [ -f "$LOG" ]; then
    if   grep -qiE 'evaluating|fetching' "$LOG" 2>/dev/null && [ $PHASE -lt 1 ]; then
      PHASE=1; _progress 1
    elif grep -qE '/nix/store.*\.drv|building path' "$LOG" 2>/dev/null && [ $PHASE -lt 2 ]; then
      PHASE=2; _progress 2
    elif grep -qE 'building the system|nix-env|nixos-rebuild' "$LOG" 2>/dev/null && [ $PHASE -lt 2 ]; then
      PHASE=2; _progress 2
    elif grep -qE 'activating|switching to system' "$LOG" 2>/dev/null && [ $PHASE -lt 3 ]; then
      PHASE=3; _progress 3
    fi
  fi
  sleep 2
done

wait $BUILD_PID
EXIT_CODE=$?

_progress 4
sleep 0.5
_close_dlg

if [ $EXIT_CODE -eq 0 ]; then
  "$KDIALOG" --title "NixOS — ${CMD}" --icon "dialog-ok" \
    --msgbox "Build complete: ${CMD}\n\nLog: ${LOG}"
else
  TAIL="$(tail -15 "$LOG" 2>/dev/null || echo '(no output)')"
  "$KDIALOG" --title "NixOS — ${CMD}" --icon "dialog-error" \
    --error "Build failed (exit ${EXIT_CODE})\n\nLast lines:\n${TAIL}\n\nFull log: ${LOG}"
fi
