#!/usr/bin/env bash
# waydroid-container entrypoint — two display architectures, selected by
# WAYDROID_DISPLAY_MODE (data-driven from build.json display.mode):
#
#   native (DEFAULT — the seamless desktop UX): the HOST desktop's Wayland socket is
#   bind-mounted into this container at /host-xdg by build.sh, and Waydroid's
#   hwcomposer connects to the host compositor (KDE) DIRECTLY — Android appears as a
#   native KDE window with ONE cursor, native touch/trackpad input, native audio
#   (host pulse socket at /host-xdg/pulse/native), zero video-encode latency. This is
#   EXACTLY how bare-metal Waydroid-on-KDE works (Waydroid core concepts: hwcomposer
#   is a Wayland CLIENT of the user's compositor, the socket is bind-mounted into
#   Android's LXC container) — the Docker layer only adds lifecycle isolation, so the
#   ghost-process class of bug cannot recur (docker stop tears everything down).
#
#   stream (headless/remote fallback): a nested headless sway (wlroots, GPU-rendered
#   via WLR_RENDER_DRM_DEVICE) + Sunshine (VAAPI hardware encode → Moonlight client)
#   + wayvnc (VNC debug transport). Remote-desktop UX with its inherent tradeoffs
#   (client-side cursor, stream latency); the right mode when no host compositor
#   exists (server, remote access).
#
# All knobs are env vars set by build.sh from build.json (data-driven) — nothing here
# is hardcoded to a specific host.
set -euo pipefail

DISPLAY_MODE="${WAYDROID_DISPLAY_MODE:-native}"
VNC_PORT="${WAYDROID_VNC_PORT:-5900}"
WIDTH="${WAYDROID_WIDTH:-1920}"
HEIGHT="${WAYDROID_HEIGHT:-1080}"
HOST_WAYLAND_DISPLAY="${WAYDROID_HOST_WAYLAND_DISPLAY:-wayland-0}"

log() { printf '[waydroid-container] %s\n' "$*"; }

# ── 1) XDG_RUNTIME_DIR (also set as an image-wide ENV in the Dockerfile so every
#    `docker exec` inherits it too, not just this entrypoint's own shell) ──────────
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime}"; export XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

# ── 2) D-Bus: system bus (waydroid container mgmt) + session bus. The session bus
#    MUST bind to the D-Bus spec's well-known $XDG_RUNTIME_DIR/bus path — libdbus
#    auto-discovers it there with NO DBUS_SESSION_BUS_ADDRESS needed, which is what
#    lets a later, separate `docker exec waydroid app install` (run by the host, not
#    a child of this shell) actually reach the running session. ────────────────────
mkdir -p /run/dbus
# On `docker start` of an EXISTING (not freshly-created) container, /run/dbus/pid
# from a previous, ungracefully-stopped session can survive on the writable layer —
# dbus-daemon's OWN startup check (via /etc/dbus-1/system.conf's <pidfile>) then
# refuses to start, seeing an apparently-stale pidfile. Since we're the only thing
# that ever writes it, any pidfile present at OUR startup is always stale — remove
# it unconditionally before launching.
rm -f /run/dbus/pid
# --print-pid writes to a SEPARATE file of ours — NOT /run/dbus/pid, dbus-daemon's
# own conventional pidfile: pre-creating that would trip its stale-pidfile check.
dbus-daemon --system --fork --print-pid=3 3>"$XDG_RUNTIME_DIR/dbus-system-ours.pid"
dbus-daemon --session --fork --address="unix:path=$XDG_RUNTIME_DIR/bus" \
  --print-pid=3 3>"$XDG_RUNTIME_DIR/dbus-session-ours.pid"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
DBUS_SYSTEM_BUS_PID="$(cat "$XDG_RUNTIME_DIR/dbus-system-ours.pid" 2>/dev/null || true)"
DBUS_SESSION_BUS_PID="$(cat "$XDG_RUNTIME_DIR/dbus-session-ours.pid" 2>/dev/null || true)"
log "D-Bus system (pid $DBUS_SYSTEM_BUS_PID) + session (pid $DBUS_SESSION_BUS_PID) up, bus at $XDG_RUNTIME_DIR/bus"

RENDER_NODE="$(find /dev/dri -name 'renderD*' 2>/dev/null | head -1)"

if [ "$DISPLAY_MODE" = "native" ]; then
  # ── NATIVE MODE: point the waydroid session at the HOST compositor. build.sh
  #    bind-mounts the host's $XDG_RUNTIME_DIR at /host-xdg; from here on the session
  #    (and Android's hwcomposer through the LXC bind-mounts waydroid derives from
  #    these env vars) talks straight to KDE. Pulse comes along for free: waydroid's
  #    LXC config mounts $XDG_RUNTIME_DIR/pulse/native = the host's pipewire-pulse
  #    socket — native audio, no in-container pulseaudio at all. ────────────────────
  [ -S "/host-xdg/$HOST_WAYLAND_DISPLAY" ] || {
    log "FATAL: host wayland socket /host-xdg/$HOST_WAYLAND_DISPLAY not present — did build.sh mount the host XDG_RUNTIME_DIR?"
    exit 1
  }
  export XDG_RUNTIME_DIR=/host-xdg
  export WAYLAND_DISPLAY="$HOST_WAYLAND_DISPLAY"
  # Same EACCES root cause as the nested-sway iteration proved via strace: Android's
  # hwcomposer runs with an init.rc capabilities ALLOW-LIST (SYS_NICE only, no
  # CAP_DAC_OVERRIDE even at uid 0) and AF_UNIX connect() needs write permission on
  # the socket inode. The host socket is user-owned; widen the FILE mode — the host's
  # /run/user/<uid> directory stays 0700, so other host users still can't reach it.
  chmod 0777 "/host-xdg/$HOST_WAYLAND_DISPLAY" 2>/dev/null || true
  [ -S /host-xdg/pulse/native ] && chmod 0777 /host-xdg/pulse/native 2>/dev/null || true
  log "native mode: session will attach to HOST compositor ($WAYLAND_DISPLAY) — one cursor, native input/audio"
else
  # ── STREAM MODE: build the full headless stack (pulse, seatd, GPU sway, wayvnc,
  #    Sunshine). See git history for the verified design notes of each piece. ──────

  # PulseAudio — waydroid's LXC config bind-mounts $XDG_RUNTIME_DIR/pulse/native;
  # a hard mount failure aborts container start without this running first.
  pulseaudio --start --exit-idle-time=-1 --daemonize=no &
  for _ in $(seq 1 20); do [ -S "$XDG_RUNTIME_DIR/pulse/native" ] && break; sleep 0.5; done
  log "PulseAudio socket: $([ -S "$XDG_RUNTIME_DIR/pulse/native" ] && echo ready || echo MISSING)"

  # seatd — wlroots initializes libseat even fully headless.
  seatd -g video &
  SEATD_PID=$!
  for _ in $(seq 1 20); do [ -S /run/seatd.sock ] && break; sleep 0.2; done
  log "seatd up (pid $SEATD_PID): $([ -S /run/seatd.sock ] && echo ready || echo MISSING)"

  # Headless sway, GPU-rendered (WLR_RENDER_DRM_DEVICE → GLES2 on the render node,
  # not pixman software). sway refuses to run as root → dedicated sway-user; grant
  # it the render node's (host-defined) gid. Config template sets the REAL declared
  # resolution (headless backend defaults to a fixed 1280x720 otherwise) and hides
  # the compositor cursor (client cursor is the pointer in remote-desktop mode —
  # moonlight-qt#1268/Sunshine#1940).
  if [ -n "$RENDER_NODE" ]; then
    RENDER_GID="$(stat -c '%g' "$RENDER_NODE")"
    getent group "$RENDER_GID" >/dev/null || groupadd -g "$RENDER_GID" host-render
    usermod -aG "$RENDER_GID" sway-user
    log "GPU render node $RENDER_NODE (gid $RENDER_GID) granted to sway-user"
  else
    log "WARNING: no /dev/dri render node — sway will fall back to software rendering"
  fi
  sed -e "s/@WIDTH@/${WIDTH}/g" -e "s/@HEIGHT@/${HEIGHT}/g" \
    /etc/sway-waydroid.conf.tpl > /etc/sway-waydroid.conf
  chown sway-user:sway-user "$XDG_RUNTIME_DIR"
  # headless,libinput: libinput INCLUDED so Sunshine's uinput virtual input devices
  # reach the compositor (host /run/udev is mounted by build.sh for libudev discovery).
  su -s /bin/sh sway-user -c \
    "XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' WLR_BACKENDS=headless,libinput WLR_LIBINPUT_NO_DEVICES=1 ${RENDER_NODE:+WLR_RENDER_DRM_DEVICE='$RENDER_NODE'} exec sway --unsupported-gpu -c /etc/sway-waydroid.conf" \
    > /var/log/sway.log 2>&1 &
  SWAY_PID=$!

  WAYLAND_SOCK=""
  for _ in $(seq 1 40); do
    WAYLAND_SOCK="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -printf '%f\n' 2>/dev/null | head -1)"
    [ -n "$WAYLAND_SOCK" ] && break
    kill -0 "$SWAY_PID" 2>/dev/null || { log "sway died — see /var/log/sway.log"; cat /var/log/sway.log; exit 1; }
    sleep 0.5
  done
  [ -n "$WAYLAND_SOCK" ] || { log "sway never created a wayland socket — see /var/log/sway.log"; cat /var/log/sway.log; exit 1; }
  export WAYLAND_DISPLAY="$WAYLAND_SOCK"
  # hwcomposer EACCES fix (init.rc capabilities allow-list strips CAP_DAC_OVERRIDE;
  # AF_UNIX connect() needs socket write permission — proven via strace).
  chmod 0777 "$XDG_RUNTIME_DIR/$WAYLAND_SOCK"
  log "sway up (pid $SWAY_PID), wayland socket $WAYLAND_DISPLAY"

  # wayvnc — VNC debug/fallback transport.
  wayvnc --output=HEADLESS-1 0.0.0.0 "$VNC_PORT" > /var/log/wayvnc.log 2>&1 &
  WAYVNC_PID=$!
  for _ in $(seq 1 20); do
    ss -tln 2>/dev/null | grep -q ":$VNC_PORT " && break
    kill -0 "$WAYVNC_PID" 2>/dev/null || { log "wayvnc died — see /var/log/wayvnc.log"; cat /var/log/wayvnc.log; exit 1; }
    sleep 0.5
  done
  log "wayvnc up (pid $WAYVNC_PID), listening VNC :$VNC_PORT"

  # Sunshine — VAAPI hardware encode of the sway output for the Moonlight client.
  # Web credentials generated once, persisted on the data volume (never in git).
  mkdir -p /var/lib/waydroid/sunshine
  SUNSHINE_PASS_FILE=/var/lib/waydroid/sunshine/web-pass
  if [ ! -f "$SUNSHINE_PASS_FILE" ]; then
    openssl rand -hex 12 > "$SUNSHINE_PASS_FILE"
    chmod 0600 "$SUNSHINE_PASS_FILE"
  fi
  sed -e "s|@RENDER_NODE@|${RENDER_NODE:-/dev/dri/renderD128}|g" \
    /etc/sunshine.conf.tpl > /etc/sunshine.conf
  sunshine /etc/sunshine.conf --creds admin "$(cat "$SUNSHINE_PASS_FILE")" \
    > /var/log/sunshine-creds.log 2>&1 || log "WARNING: sunshine --creds failed (see /var/log/sunshine-creds.log)"
  sunshine /etc/sunshine.conf > /var/log/sunshine.log 2>&1 &
  SUNSHINE_PID=$!
  for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -q ":47990 " && break
    kill -0 "$SUNSHINE_PID" 2>/dev/null || { log "WARNING: sunshine died — see /var/log/sunshine.log (VNC fallback still available)"; break; }
    sleep 0.5
  done
  log "sunshine: $(ss -tln 2>/dev/null | grep -q ':47990 ' && echo "up (pid $SUNSHINE_PID, web :47990)" || echo 'NOT LISTENING — VNC fallback only')"
fi

# ── 3) Waydroid one-time image fetch (persisted on the /data volume across restarts) ──
if [ ! -d /var/lib/waydroid/images ]; then
  log "first boot: waydroid init (fetching vendor images — this is slow, once only)…"
  waydroid init
fi

# Waydroid's OWN default LXC config mounts cgroup READ-ONLY for the guest — fine on
# bare metal, but inside Docker Android's libprocessgroup needs to CREATE its own
# cgroup subtree (/sys/fs/cgroup/uid_0) for hwcomposer/surfaceflinger. Read-only
# there is a hard, deterministic boot failure (confirmed on every fresh boot) —
# patch to rw post-init (the file is only generated by `waydroid init`).
if [ -f /var/lib/waydroid/lxc/waydroid/config ]; then
  sed -i 's/^lxc\.mount\.auto = cgroup:ro /lxc.mount.auto = cgroup:rw /' \
    /var/lib/waydroid/lxc/waydroid/config || true
fi

# ── 4) Waydroid container (Android's LXC guest) then the SESSION as a Wayland client
#    of whichever compositor $WAYLAND_DISPLAY now points at (host KDE in native mode,
#    nested sway in stream mode). ──────────────────────────────────────────────────
waydroid container start &
CONTAINER_PID=$!
for _ in $(seq 1 40); do
  waydroid status 2>/dev/null | grep -q "Session:.*STOPPED\|Session:.*RUNNING" && break
  sleep 0.5
done
log "waydroid container started"

waydroid session start &
SESSION_PID=$!
log "waydroid session start issued (WAYLAND_DISPLAY=$WAYLAND_DISPLAY, mode=$DISPLAY_MODE)"

# ── 5) Present the Android UI window. `waydroid session start` alone boots Android
#    but maps NO surface into the compositor — the UI window only appears when
#    explicitly requested via `waydroid show-full-ui` (confirmed: without it, sway's
#    window tree stayed empty while Android rendered internally). ──────────────────
for _ in $(seq 1 120); do
  waydroid status 2>/dev/null | grep -q "Session:.*RUNNING" && break
  sleep 1
done
waydroid show-full-ui &
if [ "$DISPLAY_MODE" = "stream" ]; then
  SWAYSOCK_PATH="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'sway-ipc.*.sock' | head -1)"
  UI_MAPPED=""
  for _ in $(seq 1 120); do
    if su -s /bin/sh sway-user -c "SWAYSOCK='$SWAYSOCK_PATH' swaymsg -t get_tree" 2>/dev/null \
        | grep -q '"shell": "xdg_shell"'; then
      UI_MAPPED=1; break
    fi
    sleep 1
  done
  if [ -n "$UI_MAPPED" ]; then
    log "Waydroid UI surface mapped in sway — GUI is live"
  else
    log "WARNING: Waydroid UI surface NEVER appeared in sway's tree — VNC will show a blank desktop"
  fi
else
  log "show-full-ui requested — the Waydroid window should appear on the HOST desktop (verified host-side by build.sh test)"
fi

# ── 6) Never let the display sleep — Android's screen-off timeout otherwise blanks
#    the panel after idle and the window/stream shows black (confirmed live).
#    Idempotent per boot. ────────────────────────────────────────────────────────────
for _ in $(seq 1 120); do
  [ "$(waydroid shell -- getprop sys.boot_completed 2>/dev/null | tr -d '[:space:]')" = "1" ] && break
  sleep 1
done
waydroid shell -- sh -c '
  settings put system screen_off_timeout 2147483647
  svc power stayon true
  locksettings set-disabled true
  input keyevent KEYCODE_WAKEUP
' 2>/dev/null && log "display keep-awake + lockscreen-off applied" \
  || log "WARNING: could not apply keep-awake settings (boot_completed never reached?)"

# ── 7) PID 1 duties: stay in foreground, forward SIGTERM to a FULL, ORDERED shutdown
#    of every stack this entrypoint started — graceful `waydroid ... stop` first, so
#    Android's persistent /data is never corrupted by a hard kill (the ghost-process
#    class of bug that got the original desktop-session Waydroid decommissioned). ───
term_handler() {
  log "SIGTERM received — full stack teardown…"
  waydroid session stop 2>/dev/null || true
  waydroid container stop 2>/dev/null || true
  log "  waydroid session+container stopped"
  kill "${SUNSHINE_PID:-}" 2>/dev/null || true
  wait "${SUNSHINE_PID:-}" 2>/dev/null || true
  kill "${WAYVNC_PID:-}" 2>/dev/null || true
  wait "${WAYVNC_PID:-}" 2>/dev/null || true
  kill "${SWAY_PID:-}" 2>/dev/null || true
  wait "${SWAY_PID:-}" 2>/dev/null || true
  kill "${SEATD_PID:-}" 2>/dev/null || true
  wait "${SEATD_PID:-}" 2>/dev/null || true
  pulseaudio --kill 2>/dev/null || true
  log "  display/audio stack stopped"
  [ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null || true
  [ -n "${DBUS_SYSTEM_BUS_PID:-}" ] && kill "$DBUS_SYSTEM_BUS_PID" 2>/dev/null || true
  log "  dbus stopped — teardown complete"
  exit 0
}
trap term_handler SIGTERM SIGINT

wait "$SESSION_PID" "$CONTAINER_PID" ${WAYVNC_PID:+"$WAYVNC_PID"}
