#!/usr/bin/env bash
# nixos-cp-window — NixOS Control Panel (single-process yad --list, no XEmbed IPC)
# Placeholders replaced by package.nix substituteInPlace:
#   @DATA@     nixos-cp.json (nix store)
#   @JQ@       jq binary
#   @YAD@      yad binary
set -euo pipefail

DATA="@DATA@"
JQ="@JQ@"
YAD="@YAD@"
DISPATCHER="${0%/*}/nixos-systray"

_rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR="$_rt"

# Run as native Wayland GTK — restore WAYLAND_DISPLAY unset by parent tray.sh
for _wl in 0 1 2; do
  [ -S "${_rt}/wayland-${_wl}" ] && export WAYLAND_DISPLAY="wayland-${_wl}" && break
done
unset GDK_BACKEND 2>/dev/null || true
unset XDG_SESSION_TYPE 2>/dev/null || true

export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${_rt}/bus}"
export NO_AT_BRIDGE=1

# Build flat list: Section | Action | hidden-index (global flat position)
ITEMS=()
section_count=$("$JQ" '.sections | length' "$DATA")
for (( s=0; s < section_count; s++ )); do
  sec=$("$JQ" -r --argjson s "$s" '.sections[$s].title' "$DATA")
  while IFS=$'\t' read -r lbl gidx; do
    ITEMS+=("$sec" "$lbl" "$gidx")
  done < <("$JQ" -r --argjson s "$s" \
    '([ .sections[:$s] | .[].items | length ] | add // 0) as $off |
     .sections[$s].items | to_entries[] |
     [ .value.label, (($off + .key) | tostring) ] | @tsv' \
    "$DATA")
done

result=$("$YAD" \
  --title="NixOS Control Panel" \
  --width=750 --height=520 \
  --list \
  --no-headers \
  --column="Section" \
  --column="Action" \
  --column="idx:HD" \
  --print-column=3 \
  --separator="" \
  --dclick-action="$DISPATCHER --run-index %3" \
  --button="Run!system-run:0" \
  --button="gtk-close:1" \
  "${ITEMS[@]}" 2>/dev/null) || true

[ -n "$result" ] && "$DISPATCHER" --run-index "$result"
