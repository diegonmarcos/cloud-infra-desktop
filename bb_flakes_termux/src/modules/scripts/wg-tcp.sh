#!@BASH@/bin/bash
# wg-tcp — WireGuard-over-TCP/443 fallback (Termux foreground variant)
set -eu
cmd="${1:-status}"
PIDFILE='@PID_FILE@'
LOGFILE='@LOG_FILE@'
SECRET='@SECRET_FILE@'

pid_alive() {
  [ -f "$PIDFILE" ] || return 1
  local p; p=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

case "$cmd" in
  up)
    if pid_alive; then echo "[wg-tcp] wstunnel-client already running (pid=$(cat "$PIDFILE"))"; exit 0; fi
    if [ ! -r "$SECRET" ]; then
      echo "[wg-tcp] ERROR: $SECRET not found." >&2
      echo "[wg-tcp] Put 64-char hex (sops -d <secrets.yaml>) into that file, chmod 600." >&2
      exit 1
    fi
    PATH_PREFIX="$(cat "$SECRET")"
    : >"$LOGFILE"
    @WSTUNNEL_BIN@ client \
      --local-to-remote 'udp://@LOCAL_UDP@:127.0.0.1:@REMOTE_WG@' \
      --restrict-http-upgrade-path-prefix "$PATH_PREFIX" \
      '@WS_ENDPOINT@' >>"$LOGFILE" 2>&1 &
    echo "$!" > "$PIDFILE"
    sleep 1
    if pid_alive; then
      echo "[wg-tcp] wstunnel-client up (pid=$!) — endpoint=@WS_ENDPOINT@"
      echo "[wg-tcp] log: $LOGFILE"
    else
      echo "[wg-tcp] FAILED to start — see $LOGFILE" >&2
      tail -5 "$LOGFILE" >&2 || true
      exit 1
    fi
    # Wake-lock advisory (Android kills bg processes without it)
    if ! pgrep -f termux-wake-lock >/dev/null 2>&1; then
      echo "[wg-tcp] WARNING: termux-wake-lock not held — Android may kill wstunnel when screen sleeps."
      echo "[wg-tcp] Run: termux-wake-lock"
    fi
    ;;
  down)
    if ! pid_alive; then echo "[wg-tcp] not running"; rm -f "$PIDFILE"; exit 0; fi
    p=$(cat "$PIDFILE")
    kill -TERM "$p" 2>/dev/null || true
    sleep 1
    if pid_alive; then kill -KILL "$p" 2>/dev/null || true; fi
    rm -f "$PIDFILE"
    echo "[wg-tcp] wstunnel-client down"
    ;;
  status)
    if pid_alive; then
      echo "[wg-tcp] UP — pid=$(cat "$PIDFILE")"
      echo "── log tail (@LOG_FILE@) ──"
      tail -5 "$LOGFILE" 2>/dev/null || echo "(no log)"
    else
      echo "[wg-tcp] DOWN"
    fi
    ;;
  *)
    echo "Usage: wg-tcp [up|down|status]"
    exit 1
    ;;
esac
