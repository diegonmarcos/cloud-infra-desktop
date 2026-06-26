#!/usr/bin/env bash
# nixos-systray — NixOS Control Panel system-tray icon
# Placeholders replaced by package.nix substituteInPlace:
#   @DATA@     nixos-cp.json in the nix store
#   @JQ@       jq binary
#   @YAD@      yad binary
#   @BASH@     bash binary
#   @KONSOLE@  konsole binary
#   @XDG@      xdg-open binary
set -euo pipefail

DATA="@DATA@"
JQ="@JQ@"
YAD="@YAD@"
BASH="@BASH@"
KONSOLE="@KONSOLE@"
XDG="@XDG@"

# Flake path is the only per-user value; lives in nixos-cp.json .flake
FLAKE="$("$JQ" -r '.flake' "$DATA")"

# yad --notification uses Wayland + StatusNotifier (SNI) under KDE Plasma 6.
# KDE Plasma 6 Wayland has NO XEmbed tray manager (_NET_SYSTEM_TRAY_S0 absent),
# so forcing GDK_BACKEND=x11 silently discards icons. Use native Wayland/SNI.
_rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR="$_rt"
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
  for _s in "$_rt"/wayland-[0-9]*; do
    [ -S "$_s" ] && export WAYLAND_DISPLAY="$(basename "$_s")" && break
  done
fi
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${_rt}/bus}"
export NO_AT_BRIDGE=1

_run_action() {
  local idx="$1" type arg
  type="$("$JQ" -r --argjson i "$idx" '[.sections[].items[]] | .[$i].type // empty' "$DATA")"
  arg="$( "$JQ" -r --argjson i "$idx" '[.sections[].items[]] | .[$i].arg  // empty' "$DATA")"
  arg="${arg//\{FLAKE\}/${FLAKE}}"

  case "$type" in
    build)
      # Delegate to switch-gui (kdialog progress window), in same bin/ dir
      exec "${0%/*}/nixos-switch-gui" "${arg}"
      ;;
    shell)
      exec "$KONSOLE" --hold --separate -p ColorScheme=Breeze \
        --title "NixOS" \
        -e "$BASH" -lc "${arg}; printf '\n=== done (exit %s) — close ===\n' \"\$?\""
      ;;
    log)
      exec "$KONSOLE" --hold --separate -p ColorScheme=Breeze \
        --title "NixOS build log" \
        -e "$BASH" -lc "f=\$(ls -t '${FLAKE}'/logs/build-*.log 2>/dev/null | head -1); [ -n \"\$f\" ] && tail -n 400 -f \"\$f\" || echo 'no build logs yet'"
      ;;
    open|xdg)
      exec "$XDG" "$arg"
      ;;
    *)
      echo "nixos-systray: unknown type '${type}' for index ${idx}" >&2; exit 1 ;;
  esac
}

if [ "${1:-}" = "--run-index" ]; then
  _run_action "${2:-0}"; exit
fi

tray_icon="$(   "$JQ" -r '.tray_icon    // "nix-snowflake"' "$DATA")"
tray_tooltip="$("$JQ" -r '.tray_tooltip // "NixOS"'         "$DATA")"

# Build yad menu string (label!command!icon|...) entirely in jq — no awk/paste
menuStr="$("$JQ" -r --arg self "$0" \
  '[ [.sections[].items[]] | to_entries[] |
     .value.label + "!" + ($self + " --run-index " + (.key|tostring)) + "!" + (.value.icon // "") ]
   | join("|")' \
  "$DATA")"

exec "$YAD" --notification \
  --image="$tray_icon" \
  --text="$tray_tooltip" \
  --menu="$menuStr" \
  --command="true"
