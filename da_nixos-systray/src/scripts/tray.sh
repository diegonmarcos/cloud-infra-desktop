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

# yad --notification needs X11/GTK (XWayland) even on a Wayland session
_rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -z "${DISPLAY:-}" ]; then
  for _n in 0 1 2; do [ -S "/tmp/.X11-unix/X${_n}" ] && export DISPLAY=":${_n}" && break; done
fi
if [ -z "${XAUTHORITY:-}" ]; then
  for _f in "${_rt}"/xauth_*; do [ -f "${_f}" ] && export XAUTHORITY="${_f}" && break; done
fi
unset WAYLAND_DISPLAY 2>/dev/null || true
export GDK_BACKEND=x11 NO_AT_BRIDGE=1

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
