#!/usr/bin/env bash
# nixos-switch-gui — open a Konsole window running build.sh <command>
# Can also be triggered by build.sh when DISPLAY is available.
# Placeholders replaced by package.nix substituteInPlace:
#   @DATA@     nixos-cp.json in the nix store (for flake path)
#   @JQ@       jq binary
#   @BASH@     bash binary
#   @KONSOLE@  konsole binary
set -euo pipefail

DATA="@DATA@"
JQ="@JQ@"
BASH="@BASH@"
KONSOLE="@KONSOLE@"

FLAKE="$("$JQ" -r '.flake' "$DATA")"
CMD="${1:-switch}"

exec "$KONSOLE" --hold --separate \
  -p ColorScheme=Breeze -p TerminalColumns=150 -p TerminalRows=48 \
  --title "NixOS — ${CMD}" \
  -e "$BASH" -lc \
    "cd '${FLAKE}' && PATH=/run/wrappers/bin:\$PATH NIXOS_SWITCH_GUI_RUNNING=1 ./build.sh '${CMD}'; printf '\n=== finished (exit %s) — close this window ===\n' \"\$?\""
