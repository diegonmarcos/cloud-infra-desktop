#!/usr/bin/env bash
# cloud-ide-sshd.sh
#
# Extracted from cloud-ide-sshd/default.nix (sshdScript). POSIX-ish wrapper
# for nix-on-droid sshd. Usage: cloud-ide-sshd [start|stop|status|restart]
#
# Runtime-data-driven: the WG IP and SSH port are read from
# cloud-ide-sshd.json at RUNTIME via jq (sourced from build.json at Nix
# eval time, then deployed as this small JSON — nothing else changes).
# SSHD_BIN / SSH_KEYGEN_BIN are the pinned OpenSSH 8.9p1 store paths,
# passed in via writeShellApplication's runtimeEnv (CLOUD_IDE_SSHD_BIN /
# CLOUD_IDE_SSH_KEYGEN_BIN) — dodges the proot execveat-with-fd
# limitation that breaks 9.x child processes on Android. See
# pkgs/openssh-pinned.nix for the full story.
#
# Key material handling: HOST_KEY/SSHD_CONFIG below are PATHS ONLY. No key
# material, passphrase, or token is ever read into a variable, printed, or
# written into the runtime JSON — ssh-keygen writes the host key straight
# to disk under $HOME/.ssh, and sshd is pointed at it via the `HostKey`
# directive in the config file this script writes. authorized_keys content
# (trusted pubkeys + sops-decrypted Cloud IDE key) is populated separately
# by cloud-ide-sshd/default.nix's home.activation.cloudIdeAuthorizedKeys —
# unchanged by this extraction.
set -uo pipefail

SSHD_BIN="${CLOUD_IDE_SSHD_BIN:?cloud-ide-sshd.sh: CLOUD_IDE_SSHD_BIN not set by Nix module}"
SSH_KEYGEN_BIN="${CLOUD_IDE_SSH_KEYGEN_BIN:?cloud-ide-sshd.sh: CLOUD_IDE_SSH_KEYGEN_BIN not set by Nix module}"

CONFIG_JSON="${CLOUD_IDE_SSHD_CONFIG_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/cloud-ide-sshd.json}"
if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  echo "cloud-ide-sshd: ERROR: $CONFIG_JSON missing or unreadable" >&2
  exit 1
fi

WG_IP="$(jq -r '.wg_ip' "$CONFIG_JSON")"
SSH_PORT="$(jq -r '.ssh_port' "$CONFIG_JSON")"

PID_FILE="$HOME/.cache/sshd.pid"
LOG_FILE="$HOME/.cache/sshd.log"
HOST_KEY="$HOME/.ssh/ssh_host_rsa_key"
SSHD_CONFIG="$HOME/.ssh/sshd_config"

is_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

# Returns the PID(s) of any process currently listening on :$SSH_PORT, regardless
# of whether it's tracked by our PID file. Used to detect orphans from a
# previous start where the PID file got nuked but the process survived.
port_holder_pids() {
  ss -tlnp 2>/dev/null | awk -v port="$SSH_PORT" '$0 ~ ":" port " " {
    # ss output: ... users:(("sshd",pid=12345,fd=3))
    match($0, /pid=[0-9]+/);
    if (RSTART) print substr($0, RSTART+4, RLENGTH-4)
  }' | sort -u
  # Fallback for Android/proot ss without -p detail: try fuser/lsof if present.
  if [ -z "$(ss -tlnp 2>/dev/null | grep ":$SSH_PORT ")" ]; then
    :  # nothing on port
  fi
}

# Self-heal step before do_start: if something else is on :$SSH_PORT but our
# PID file is missing/stale, kill the orphan. Idempotent — safe to run
# whether or not anything is wrong.
self_heal() {
  _occupied=$(ss -tln 2>/dev/null | grep ":$SSH_PORT " || true)
  if [ -n "$_occupied" ] && ! is_running; then
    # Port bound but we don't own it via PID file — orphan.
    _orphans=$(port_holder_pids)
    if [ -n "$_orphans" ]; then
      echo "self-heal: orphan(s) on :$SSH_PORT (PID $_orphans) — killing"
      for _p in $_orphans; do
        kill -9 "$_p" 2>/dev/null || true
      done
    else
      # No process info from ss. Carpet-bomb anything matching sshd.
      echo "self-heal: :$SSH_PORT bound but PID unknown — pkill sshd"
      pkill -9 -f 'sshd|dropbear' 2>/dev/null || true
    fi
    # Clear stale PID file
    rm -f "$PID_FILE"
    sleep 0.4
  elif [ -f "$PID_FILE" ] && ! kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    # PID file exists but process is gone.
    rm -f "$PID_FILE"
  fi
}

do_start() {
  self_heal

  # ListenAddress lines: 127.0.0.1 ALWAYS (the Cloud IDE APK connects over
  # loopback), plus the WG IP when wg0 is actually up. Best-effort probe:
  # if `ip` is unavailable we keep the WG bind (previous behavior).
  WG_LISTEN="ListenAddress $WG_IP"
  if command -v ip >/dev/null 2>&1; then
    if ! ip -o addr show 2>/dev/null | grep -q "inet $WG_IP"; then
      WG_LISTEN="# wg0 ($WG_IP) not up — binding loopback only"
    fi
  fi

  if is_running; then
    pid=$(cat "$PID_FILE")
    echo "sshd already running (PID $pid) on :$SSH_PORT"
    return 0
  fi

  mkdir -p ~/.ssh "$(dirname "$PID_FILE")"
  chmod 700 ~/.ssh

  # Host key — RSA (matches maintainer recipe; sshd accepts ed25519 too
  # but RSA is what they tested under proot).
  if [ ! -f "$HOST_KEY" ]; then
    "$SSH_KEYGEN_BIN" -t rsa -b 4096 -f "$HOST_KEY" -N "" -q
    echo "Generated host key: $HOST_KEY"
  fi

  # Write sshd_config (idempotent, regenerated each start so changes flow
  # through the wrapper without manual edits). ListenAddress is the WG IP
  # from build.json — bind ONLY to wg0, no public exposure. If wg0 isn't
  # up at start time sshd will fail to bind and the wrapper will log it.
  cat > "$SSHD_CONFIG" <<EOF
HostKey $HOST_KEY
ListenAddress 127.0.0.1
$WG_LISTEN
Port $SSH_PORT
PidFile $PID_FILE
AuthorizedKeysFile $HOME/.ssh/authorized_keys
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
EOF
  chmod 600 "$SSHD_CONFIG"

  if [ -x "$SSHD_BIN" ]; then
    "$SSHD_BIN" -f "$SSHD_CONFIG" >> "$LOG_FILE" 2>&1
    sleep 0.5
    if is_running; then
      pid=$(cat "$PID_FILE")
      echo "sshd started (PID $pid) on :$SSH_PORT"
    else
      # Self-heal retry: address-already-in-use is a common failure mode
      # when the orphan check above didn't catch the holder. Force-kill
      # anything on the port and try one more time before giving up.
      if grep -q "Address already in use" "$LOG_FILE" 2>/dev/null; then
        echo "self-heal: address-already-in-use — purging and retrying"
        pkill -9 -f "sshd|dropbear" 2>/dev/null || true
        sleep 0.5
        "$SSHD_BIN" -f "$SSHD_CONFIG" >> "$LOG_FILE" 2>&1
        sleep 0.5
      fi
      if is_running; then
        pid=$(cat "$PID_FILE")
        echo "sshd started (PID $pid) on :$SSH_PORT (after self-heal)"
      else
        echo "sshd failed to start — last 15 lines of $LOG_FILE:"
        tail -15 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
        return 1
      fi
    fi
  else
    echo "ERROR: sshd not found at $SSHD_BIN (run nix-on-droid switch first)"
    return 1
  fi
}

do_stop() {
  if is_running; then
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null
    rm -f "$PID_FILE"
    echo "sshd stopped (was PID $pid)"
  else
    rm -f "$PID_FILE"
    echo "sshd not running"
  fi
}

do_status() {
  if is_running; then
    pid=$(cat "$PID_FILE")
    echo "sshd running (PID $pid) on :$SSH_PORT"
  else
    rm -f "$PID_FILE"
    echo "sshd not running"
  fi
}

case "${1:-start}" in
  start)   do_start ;;
  stop)    do_stop ;;
  status)  do_status ;;
  restart) do_stop; sleep 0.3; do_start ;;
  *)       echo "Usage: cloud-ide-sshd {start|stop|status|restart}"; exit 1 ;;
esac
