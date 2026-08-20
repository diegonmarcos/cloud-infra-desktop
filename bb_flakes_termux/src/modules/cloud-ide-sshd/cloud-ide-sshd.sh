#!/usr/bin/env bash
# cloud-ide-sshd.sh
#
# Extracted from cloud-ide-sshd/default.nix (sshdScript). POSIX-ish wrapper
# for nix-on-droid sshd. Usage: cloud-ide-sshd [start|stop|status|restart|ensure]
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

# The phone carries ONE identity across several mesh addresses (v4 via one hub,
# v4-public and v6 via another) and the active WireGuard profile decides which
# of them the interface actually holds. Binding only wg_ip meant that picking a
# v6 profile left sshd with nothing but loopback — reachable from the phone and
# from nowhere else. Bind every mesh address; sshd warns about the ones the
# current profile does not carry and serves the rest (see bind-policy note).
WG_IPS="$(jq -r 'if (.wg_ips // empty) then .wg_ips[] else .wg_ip end' "$CONFIG_JSON")"

# A wildcard here would be a public bind on a carrier network — the one thing
# this file exists to prevent. Drop them rather than trust the config: this list
# now comes from build.json, so a typo upstream must not open the phone up.
WG_IPS="$(printf '%s\n' "$WG_IPS" | grep -vxE '0\.0\.0\.0|::|\*|' || true)"
[ -n "$WG_IPS" ] || WG_IPS="$WG_IP"

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
  # No fallback for Android/proot ss without -p detail: the block that used to
  # sit here had an empty body, so it never did anything. It also tripped SC2143
  # ([ -z "$(... | grep ...)" ] instead of ! grep -q), which is fatal under
  # writeShellApplication. Callers already treat "no pid printed" as "nothing on
  # port", so dropping it changes no behaviour.
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

# Is sshd ACTUALLY accepting on $WG_IP:$SSH_PORT right now?
#
# This asks the socket table, not the interface list, and that distinction is
# the whole bug. `ip addr` inside nix-on-droid cannot be trusted to see the
# VPN interface: Android restricts netlink interface enumeration for app-uid
# processes, so `ip -o addr show | grep "inet 10.0.0.9"` comes back empty on a
# phone whose WireGuard is perfectly up. The old code took that empty result
# as "wg0 is down", dropped the WG ListenAddress, and started a loopback-only
# daemon that cheerfully announced "sshd started on :8024" while every mesh
# peer got connection-refused.
#
# ss reads /proc/net/tcp, which always shows sockets owned by our own uid —
# no Android restriction applies. A listener either exists or it does not.
listening_on_wg() {
  command -v ss >/dev/null 2>&1 || return 0   # cannot tell -> do not thrash

  _ss=$(ss -tln 2>/dev/null)

  # `ss` being PRESENT is not the same as `ss` being able to SEE anything.
  # Confirmed on galaxy 2026-08-20: an established inbound session was running
  # and `ss -tln | grep 8024` still printed nothing, because Android restricts
  # /proc/net visibility for app-uid processes much as it does netlink.
  #
  # So the empty result has two meanings — "nothing is listening" and "I am not
  # allowed to see what is listening" — and acting on the wrong one is how the
  # interface probe broke this in the first place. Distinguish them: if sshd is
  # up, at least ONE LISTEN row must be visible to a working ss. Zero rows means
  # blind, not idle, and blind must answer "assume fine" or ensure would rebind
  # on every cooldown forever against a daemon that was never broken.
  case "$_ss" in
    *LISTEN*) : ;;
    *)        return 0 ;;
  esac

  # Any mesh address counts as healthy: the active WireGuard profile decides
  # which one the interface carries, so demanding a specific one would call a
  # perfectly reachable v6-profile daemon degraded and rebind it forever.
  # ss renders v6 as [addr]:port, so match the address followed by ]:port too.
  # Braces per 1e46b948: shellcheck reads $SSH_PORT[[:space:]] as an array index.
  for _ip in $WG_IPS 0.0.0.0 '*'; do
    printf '%s\n' "$_ss" | grep -qF "$_ip:${SSH_PORT}"   && return 0
    printf '%s\n' "$_ss" | grep -qF "[$_ip]:${SSH_PORT}" && return 0
  done
  return 1
}

# Rebinding is cheap, but if wg0 is genuinely down it can never succeed, and
# fish runs ensure on every new shell. Cool down so a truly-offline tunnel
# costs one restart attempt per interval instead of one per terminal.
# ── wake lock ────────────────────────────────────────────────────────────
# Android's Doze reaps proot children while the device idles. That killed sshd
# three times on 2026-08-20, and NO other layer here covers it: the boot hook
# only fires on a real boot, and fish's shellInit needs a human already holding
# the phone. So the daemon comes back only by physically unlocking the device —
# which is exactly when remote access is wanted and unavailable.
#
# A wake lock is what tells Android not to suspend the app. There is no
# `termux-wake-lock` binary in nix-on-droid (the wireguard-wstunnel.sh advisory
# predates this environment); the lock is an Android intent, and the action
# constant differs between Termux and its nix-on-droid fork. Rather than guess
# one string, try each and stop at the first that is accepted.
#
# Best-effort by design: every branch can fail, and sshd must still start. A
# phone that is reachable until Doze beats a phone that refused to boot sshd
# because an intent was rejected.
WAKELOCK_STAMP="$HOME/.cache/sshd.wakelock"

wake_lock_held() {
  # The stamp is the only signal available: `am` reports delivery, not state,
  # and Doze kills the process without clearing anything it wrote.
  pgrep -f 'termux-wake-lock' >/dev/null 2>&1 && return 0
  [ -f "$WAKELOCK_STAMP" ]
}

acquire_wake_lock() {
  wake_lock_held && return 0

  if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock >/dev/null 2>&1 && {
      : > "$WAKELOCK_STAMP" 2>/dev/null || true
      echo "wake lock: acquired via termux-wake-lock"
      return 0
    }
  fi

  command -v am >/dev/null 2>&1 || {
    echo "wake lock: no termux-wake-lock and no am — Doze WILL kill this daemon" >&2
    return 1
  }

  # com.termux.nix first: this environment is the fork, so its own constant is
  # the likelier one. The upstream Termux action is the fallback because the
  # fork may not have renamed it.
  for _act in com.termux.nix.service_wake_lock com.termux.service_wake_lock; do
    if am startservice -a "$_act" \
         com.termux.nix/com.termux.app.TermuxService >/dev/null 2>&1; then
      : > "$WAKELOCK_STAMP" 2>/dev/null || true
      echo "wake lock: acquired via intent $_act"
      return 0
    fi
  done

  echo "wake lock: every intent rejected — Doze WILL kill this daemon" >&2
  return 1
}

REBIND_STAMP="$HOME/.cache/sshd.rebind-stamp"
REBIND_COOLDOWN=120
rebind_allowed() {
  [ -f "$REBIND_STAMP" ] || return 0
  _now=$(date +%s 2>/dev/null || echo 0)
  _then=$(cat "$REBIND_STAMP" 2>/dev/null || echo 0)
  [ $((_now - _then)) -ge "$REBIND_COOLDOWN" ]
}

# start-if-dead, restart-if-degraded. This is what fish shellInit calls.
#
# The bug this fixes: sshd used to be started only when the pid file was
# missing or stale. Open a shell before wg0 is up and sshd binds loopback
# alone, writes its pid file, and is_running answers "yes" forever after —
# so nothing ever re-binds once wg0 appears. The daemon reports healthy, and
# the phone answers ICMP on the mesh while :$SSH_PORT returns RST. That state
# is invisible from the device and only shows up as "connection refused" from
# another peer, which is the worst possible place to discover it.
do_ensure() {
  if ! is_running; then
    do_start
    return $?
  fi
  if ! listening_on_wg; then
    if ! rebind_allowed; then
      return 0
    fi
    echo "ensure: alive but not accepting on $WG_IP:$SSH_PORT — rebinding"
    date +%s > "$REBIND_STAMP" 2>/dev/null || true
    do_stop
    sleep 0.3
    do_start
    return $?
  fi
  return 0
}

do_start() {
  self_heal

  # ListenAddress: wg0 and loopback, unconditionally, with NO interface probe.
  #
  # There used to be a probe here that dropped the WG line when `ip addr` could
  # not see the address. On Android that probe returns empty for reasons that
  # have nothing to do with whether the tunnel is up (see listening_on_wg), so
  # it removed the only listener that matters while reporting success.
  #
  # Letting sshd's own bind() decide is both simpler and correct. sshd warns on
  # a ListenAddress it cannot bind and carries on with the rest, failing only
  # if none of them work — so a genuinely-down wg0 degrades to loopback exactly
  # as before, but a working one is never discarded on bad evidence.
  #
  # A PUBLIC BIND IS FORBIDDEN. These two lines are the entire policy: there is
  # no branch that can emit 0.0.0.0, and none that can omit ListenAddress
  # altogether — the latter is the dangerous one, because sshd with no
  # ListenAddress binds every interface, which on a phone is the carrier
  # network.

  if is_running; then
    pid=$(cat "$PID_FILE")
    echo "sshd already running (PID $pid) on :$SSH_PORT"
    return 0
  fi

  mkdir -p ~/.ssh "$(dirname "$PID_FILE")"
  chmod 700 ~/.ssh

  # Host key — RSA (matches maintainer recipe; sshd accepts ed25519 too
  # but RSA is what they tested under proot).
  # Before the daemon, not after: if Doze reaps us mid-start the lock is what
  # keeps the next attempt from being needed at all.
  acquire_wake_lock || true

  if [ ! -f "$HOST_KEY" ]; then
    "$SSH_KEYGEN_BIN" -t rsa -b 4096 -f "$HOST_KEY" -N "" -q
    echo "Generated host key: $HOST_KEY"
  fi

  # Write sshd_config (idempotent, regenerated each start so changes flow
  # through the wrapper without manual edits). See the bind-policy comment
  # above: wg0 + loopback, never public, no interface probe.
  # shellcheck disable=SC2086  # $WG_IPS word-splitting is the point: one ListenAddress line per mesh IP
  cat > "$SSHD_CONFIG" <<EOF
HostKey $HOST_KEY
$(printf 'ListenAddress %s\n' $WG_IPS)
ListenAddress 127.0.0.1
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
    if listening_on_wg; then
      echo "sshd running (PID $pid) on :$SSH_PORT ($WG_IP + 127.0.0.1)"
    else
      echo "sshd running (PID $pid) on :$SSH_PORT (127.0.0.1 ONLY — not reachable over wg0; run: cloud-ide-sshd ensure)"
    fi
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
  ensure)  do_ensure ;;
  *)       echo "Usage: cloud-ide-sshd {start|stop|status|restart|ensure}"; exit 1 ;;
esac
