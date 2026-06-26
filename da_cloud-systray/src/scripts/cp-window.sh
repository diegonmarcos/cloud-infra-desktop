#!/usr/bin/env bash
# cloud-cp-window — left-click control panel: section sidebar (left tabs) + item list
# Placeholders replaced by package.nix substituteInPlace:
#   @DATA@     cloud-cp.json (nix store)
#   @JQ@       jq binary
#   @YAD@      yad binary
#   @BASH@     bash binary
set -euo pipefail

DATA="@DATA@"
JQ="@JQ@"
YAD="@YAD@"
BASH="@BASH@"

# --- X11 env (same discovery as tray.sh) ---
_rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR="$_rt"
if [ -z "${DISPLAY:-}" ]; then
  for _n in 0 1 2; do [ -S "/tmp/.X11-unix/X${_n}" ] && export DISPLAY=":${_n}" && break; done
fi
if [ -z "${XAUTHORITY:-}" ]; then
  for _f in "${_rt}"/xauth_*; do [ -f "$_f" ] && export XAUTHORITY="$_f" && break; done
fi
unset WAYLAND_DISPLAY 2>/dev/null || true
export GDK_BACKEND=x11 NO_AT_BRIDGE=1
export XDG_SESSION_TYPE=x11
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${_rt}/bus}"

# cloud-systray in same bin/ handles action dispatch via --run-index N
DISPATCHER="${0%/*}/cloud-systray"

KEY=$RANDOM

# Start notebook container — tab-pos=left gives sidebar appearance
"$YAD" --notebook \
  --key="$KEY" \
  --tab-pos=left \
  --title="Cloud & Infra Control Panel" \
  --width=900 --height=600 \
  --button="gtk-close:0" &
PARENT_PID=$!

# One plug per section; items get their global flat index as hidden column
section_count=$("$JQ" '.sections | length' "$DATA")

for (( s=0; s < section_count; s++ )); do
  sec_title=$("$JQ" -r --argjson s "$s" '.sections[$s].title' "$DATA")

  LIST_ARGS=()
  while IFS=$'\t' read -r lbl gidx; do
    LIST_ARGS+=("$lbl" "$gidx")
  done < <("$JQ" -r --argjson s "$s" \
    '([ .sections[:$s] | .[].items | length ] | add // 0) as $off |
     .sections[$s].items | to_entries[] |
     [ .value.label, (($off + .key) | tostring) ] | @tsv' \
    "$DATA")

  DCLICK="${DISPATCHER} --run-index %2"

  "$YAD" --plug="$KEY" \
    --tabnum=$(( s + 1 )) \
    --tab="$sec_title" \
    --list \
    --no-headers \
    --column="Action" \
    --column="idx:HD" \
    --print-column=2 \
    --separator="" \
    --dclick-action="$DCLICK" \
    --button="Run!system-run:0" \
    "${LIST_ARGS[@]}" &
done

wait "$PARENT_PID"
