#!/usr/bin/env bash
# waydroid-container entrypoint — boots D-Bus (system+session), a headless weston
# compositor (RDP backend), PulseAudio, then Waydroid itself as a WAYLAND CLIENT of
# that weston compositor. This last wiring (WAYLAND_DISPLAY pointed at weston's own
# socket before `waydroid session start`) is the piece that was never done in the
# throwaway manual test — without it Waydroid has nothing to render into and RDP
# shows a black/empty desktop even though every subsystem underneath is healthy.
#
# All knobs are env vars set by build.sh from build.json (data-driven) — nothing here
# is hardcoded to a specific host.
set -euo pipefail

RDP_PORT="${WAYDROID_RDP_PORT:-3389}"
WIDTH="${WAYDROID_WIDTH:-1920}"
HEIGHT="${WAYDROID_HEIGHT:-1080}"
GPU_MODE="${WAYDROID_GPU_MODE:-host}"

log() { printf '[waydroid-container] %s\n' "$*"; }

# ── 1) XDG_RUNTIME_DIR (also set as an image-wide ENV in the Dockerfile so every
#    `docker exec` inherits it too, not just this entrypoint's own shell) ──────────
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime}"; export XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

# ── 2) D-Bus: system bus (waydroid container mgmt) + session bus (weston/pulseaudio/
#    waydroid session). The session bus MUST bind to the D-Bus spec's well-known
#    $XDG_RUNTIME_DIR/bus path — libdbus auto-discovers it there with NO
#    DBUS_SESSION_BUS_ADDRESS needed, which is what lets a later, separate `docker
#    exec waydroid app install` (run by the host, not a child of this shell) actually
#    reach the running session instead of falsely reporting "session is stopped". ──
mkdir -p /run/dbus
dbus-daemon --system --fork
dbus-daemon --session --fork --address="unix:path=$XDG_RUNTIME_DIR/bus"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
log "D-Bus system+session up (session bus at $XDG_RUNTIME_DIR/bus)"

# ── 3) PulseAudio — Waydroid's LXC config bind-mounts $XDG_RUNTIME_DIR/pulse/native;
#    a hard mount failure aborts container start without this running first. ──────
pulseaudio --start --exit-idle-time=-1 --daemonize=no &
for _ in $(seq 1 20); do [ -S "$XDG_RUNTIME_DIR/pulse/native" ] && break; sleep 0.5; done
log "PulseAudio socket: $([ -S "$XDG_RUNTIME_DIR/pulse/native" ] && echo ready || echo MISSING)"

# ── 4) weston RDP backend needs a TLS keypair (no --rdp-user/--rdp-pass in this
#    Debian package — --rdp-tls-cert/--rdp-tls-key is the only auth-transport option). ──
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "$XDG_RUNTIME_DIR/rdp.key" -out "$XDG_RUNTIME_DIR/rdp.crt" \
  -subj "/CN=waydroid-container" >/dev/null 2>&1

# ── 5) headless weston, RDP backend. Backgrounded; then WAIT for its wayland socket
#    to actually appear (the socket name is compositor-assigned, not ours to pick) ──
weston --backend=rdp-backend.so \
  --width="$WIDTH" --height="$HEIGHT" \
  --rdp-tls-cert="$XDG_RUNTIME_DIR/rdp.crt" --rdp-tls-key="$XDG_RUNTIME_DIR/rdp.key" \
  --port="$RDP_PORT" \
  --idle-time=0 \
  > /var/log/weston.log 2>&1 &
WESTON_PID=$!

WAYLAND_SOCK=""
for _ in $(seq 1 40); do
  WAYLAND_SOCK="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -printf '%f\n' 2>/dev/null | head -1)"
  [ -n "$WAYLAND_SOCK" ] && break
  kill -0 "$WESTON_PID" 2>/dev/null || { log "weston died — see /var/log/weston.log"; cat /var/log/weston.log; exit 1; }
  sleep 0.5
done
[ -n "$WAYLAND_SOCK" ] || { log "weston never created a wayland socket — see /var/log/weston.log"; cat /var/log/weston.log; exit 1; }
export WAYLAND_DISPLAY="$WAYLAND_SOCK"
log "weston up (pid $WESTON_PID), listening RDP :$RDP_PORT, wayland socket $WAYLAND_DISPLAY"

# ── 6) Waydroid one-time image fetch (persisted on the /data volume across restarts) ──
if [ ! -d /var/lib/waydroid/images ]; then
  log "first boot: waydroid init (fetching vendor images — this is slow, once only)…"
  waydroid init
fi

# gpu_mode is data-driven (build.json waydroid.gpu_mode) — patch the cfg after init
# rather than hardcoding it into the image, since it's a runtime/host capability choice.
if [ -f /var/lib/waydroid/waydroid.cfg ]; then
  sed -i "s/^gpu_mode = .*/gpu_mode = ${GPU_MODE}/" /var/lib/waydroid/waydroid.cfg || true
fi

# ── 7) Waydroid container (Android's own LXC container — binder/ashmem-free vendor
#    image) then the SESSION as a Wayland CLIENT of the weston compositor started
#    above. This ordering + WAYLAND_DISPLAY export is the step that was missing. ──
waydroid container start &
CONTAINER_PID=$!
for _ in $(seq 1 40); do
  waydroid status 2>/dev/null | grep -q "Session:.*STOPPED\|Session:.*RUNNING" && break
  sleep 0.5
done
log "waydroid container started"

waydroid session start &
SESSION_PID=$!
log "waydroid session start issued (WAYLAND_DISPLAY=$WAYLAND_DISPLAY) — attaching as weston client"

# ── 8) PID 1 duties: stay in foreground, forward SIGTERM to a clean waydroid+weston
#    shutdown (docker stop sends SIGTERM — without a trap, Android state can corrupt) ──
term_handler() {
  log "SIGTERM received — stopping waydroid session/container, then weston…"
  waydroid session stop 2>/dev/null || true
  waydroid container stop 2>/dev/null || true
  kill "$WESTON_PID" 2>/dev/null || true
  exit 0
}
trap term_handler SIGTERM SIGINT

wait "$SESSION_PID" "$CONTAINER_PID" "$WESTON_PID"
