#!/usr/bin/env bash
# cloud-systray — Cloud & Infra control-panel system-tray icon
# Placeholders replaced by package.nix substituteInPlace:
#   @DATA@     cloud-cp.json in the nix store
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

# All flake paths read from JSON — change cloud-cp.json, not this script
FLAKE_SYSTEM="$( "$JQ" -r '.flake_system'  "$DATA")"
FLAKE_DESKTOP="$("$JQ" -r '.flake_desktop' "$DATA")"
FLAKE_CLOUD="$(  "$JQ" -r '.flake_cloud'   "$DATA")"

# yad --notification needs X11/GTK (XWayland) even on a Wayland session
_rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -z "${DISPLAY:-}" ]; then
  for _n in 0 1 2; do [ -S "/tmp/.X11-unix/X${_n}" ] && export DISPLAY=":${_n}" && break; done
fi
if [ -z "${XAUTHORITY:-}" ]; then
  for _f in "${_rt}"/xauth_*; do [ -f "${_f}" ] && export XAUTHORITY="${_f}" && break; done
fi
export GDK_BACKEND=x11 NO_AT_BRIDGE=1

_expand() {
  local s="$1"
  s="${s//\{FLAKE_SYSTEM\}/${FLAKE_SYSTEM}}"
  s="${s//\{FLAKE_DESKTOP\}/${FLAKE_DESKTOP}}"
  s="${s//\{FLAKE_CLOUD\}/${FLAKE_CLOUD}}"
  s="${s//\{FLAKE\}/${FLAKE_SYSTEM}}"
  printf '%s' "$s"
}

_build_konsole() {
  local flake="$1" arg="$2"
  exec "$KONSOLE" --hold --separate \
    -p ColorScheme=Breeze -p TerminalColumns=150 -p TerminalRows=48 \
    --title "NixOS — ${arg}" \
    -e "$BASH" -lc "cd '${flake}' && PATH=/run/wrappers/bin:\$PATH ./build.sh '${arg}'; printf '\n=== finished (exit %s) ===\n' \"\$?\""
}

_run_action() {
  local idx="$1" type arg
  type="$("$JQ" -r --argjson i "$idx" '[.sections[].items[]] | .[$i].type // empty' "$DATA")"
  arg="$(  "$JQ" -r --argjson i "$idx" '[.sections[].items[]] | .[$i].arg  // empty' "$DATA")"
  arg="$(_expand "$arg")"

  case "$type" in
    shell)
      exec "$KONSOLE" --hold --separate -p ColorScheme=Breeze \
        --title "Cloud" \
        -e "$BASH" -lc "${arg}; printf '\n=== done (exit %s) — close ===\n' \"\$?\""
      ;;
    build-system)   _build_konsole "$FLAKE_SYSTEM"  "$arg" ;;
    build-desktop)  _build_konsole "$FLAKE_DESKTOP" "$arg" ;;
    log-system)
      exec "$KONSOLE" --hold --separate -p ColorScheme=Breeze --title "System build log" \
        -e "$BASH" -lc "f=\$(ls -t '${FLAKE_SYSTEM}'/logs/build-*.log 2>/dev/null | head -1); [ -n \"\$f\" ] && tail -n 400 -f \"\$f\" || echo 'no build logs yet'"
      ;;
    log-desktop)
      exec "$KONSOLE" --hold --separate -p ColorScheme=Breeze --title "Desktop build log" \
        -e "$BASH" -lc "f=\$(ls -t '${FLAKE_DESKTOP}'/logs/build-*.log 2>/dev/null | head -1); [ -n \"\$f\" ] && tail -n 400 -f \"\$f\" || echo 'no build logs yet'"
      ;;
    xdg)
      exec "$XDG" "$arg" ;;
    *)
      echo "cloud-systray: unknown type '${type}' for index ${idx}" >&2; exit 1 ;;
  esac
}

if [ "${1:-}" = "--run-index" ]; then
  _run_action "${2:-0}"; exit
fi

tray_icon="$(   "$JQ" -r '.tray_icon    // "network-vpn"'    "$DATA")"
tray_tooltip="$("$JQ" -r '.tray_tooltip // "Cloud & Infra"'  "$DATA")"

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
