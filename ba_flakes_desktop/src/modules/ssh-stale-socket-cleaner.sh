#!/bin/sh
# SSH stale socket cleaner — kills dead ControlMaster mux sockets
# Runs every 2 minutes via systemd timer
# Source: unix/ba_flakes_desktop/src/modules/ssh-stale-socket-cleaner.sh

SOCKET_DIR="$HOME/.ssh/sockets"
[ -d "$SOCKET_DIR" ] || exit 0

CLEANED=0
for sock in "$SOCKET_DIR"/*; do
  [ -e "$sock" ] || continue
  # ssh -O check tests if the mux master is alive
  if ! ssh -O check -o ControlPath="$sock" dummy 2>/dev/null; then
    rm -f "$sock"
    CLEANED=$((CLEANED + 1))
  fi
done

[ "$CLEANED" -gt 0 ] && echo "[ssh-socket-cleaner] Removed $CLEANED stale socket(s)"
exit 0
