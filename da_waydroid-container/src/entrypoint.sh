#!/usr/bin/env bash
# waydroid-container entrypoint — boots D-Bus (system+session), a headless sway
# (wlroots) compositor exported over VNC via wayvnc, PulseAudio, then Waydroid itself
# as a WAYLAND CLIENT of that compositor. This wiring (WAYLAND_DISPLAY pointed at
# sway's own socket before `waydroid session start`) is what makes Waydroid actually
# have something to render into.
#
# sway+wayvnc, not weston+rdp-backend: Debian bookworm's weston 10.0.1 rdp-backend.so
# has a confirmed dead-connection bug (accepts the TCP handshake, never services the
# RDP protocol negotiation — isolated via fresh-container + single-client +
# thread-count + backtrace tests, 2026-07-04). sway+wayvnc is the standard,
# actively-maintained combo for headless-Wayland VNC.
#
# All knobs are env vars set by build.sh from build.json (data-driven) — nothing here
# is hardcoded to a specific host.
set -euo pipefail

VNC_PORT="${WAYDROID_VNC_PORT:-5900}"
WIDTH="${WAYDROID_WIDTH:-1920}"
HEIGHT="${WAYDROID_HEIGHT:-1080}"
GPU_MODE="${WAYDROID_GPU_MODE:-host}"

log() { printf '[waydroid-container] %s\n' "$*"; }

# ── 1) XDG_RUNTIME_DIR (also set as an image-wide ENV in the Dockerfile so every
#    `docker exec` inherits it too, not just this entrypoint's own shell) ──────────
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime}"; export XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

# ── 2) D-Bus: system bus (waydroid container mgmt) + session bus (sway/wayvnc/
#    pulseaudio/waydroid session). The session bus MUST bind to the D-Bus spec's well-known
#    $XDG_RUNTIME_DIR/bus path — libdbus auto-discovers it there with NO
#    DBUS_SESSION_BUS_ADDRESS needed, which is what lets a later, separate `docker
#    exec waydroid app install` (run by the host, not a child of this shell) actually
#    reach the running session instead of falsely reporting "session is stopped". ──
mkdir -p /run/dbus
# On `docker start` of an EXISTING (not freshly-created) container, /run/dbus/pid
# from a previous, ungracefully-stopped session can survive on the writable layer —
# dbus-daemon's OWN startup check (via /etc/dbus-1/system.conf's <pidfile>) then
# refuses to start, seeing an apparently-stale pidfile. Since we're the only thing
# that ever writes it, any pidfile present at OUR startup is always stale — remove
# it unconditionally before launching. This is the exact restart path build.sh's
# `docker start` (existing container) takes, so this recurs every time without it.
rm -f /run/dbus/pid
# --print-pid writes to a SEPARATE file of ours ($XDG_RUNTIME_DIR/dbus-*-ours.pid) —
# NOT /run/dbus/pid, which is dbus-daemon's OWN conventional system-bus pidfile
# (declared in /etc/dbus-1/system.conf's <pidfile>). Redirecting fd 3 there would
# pre-create/truncate that file before dbus-daemon's own startup check runs, which
# then sees an apparently-stale pidfile and refuses to start.
dbus-daemon --system --fork --print-pid=3 3>"$XDG_RUNTIME_DIR/dbus-system-ours.pid"
dbus-daemon --session --fork --address="unix:path=$XDG_RUNTIME_DIR/bus" \
  --print-pid=3 3>"$XDG_RUNTIME_DIR/dbus-session-ours.pid"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
DBUS_SYSTEM_BUS_PID="$(cat "$XDG_RUNTIME_DIR/dbus-system-ours.pid" 2>/dev/null || true)"
DBUS_SESSION_BUS_PID="$(cat "$XDG_RUNTIME_DIR/dbus-session-ours.pid" 2>/dev/null || true)"
log "D-Bus system (pid $DBUS_SYSTEM_BUS_PID) + session (pid $DBUS_SESSION_BUS_PID) up, bus at $XDG_RUNTIME_DIR/bus"

# ── 3) PulseAudio — Waydroid's LXC config bind-mounts $XDG_RUNTIME_DIR/pulse/native;
#    a hard mount failure aborts container start without this running first. ──────
pulseaudio --start --exit-idle-time=-1 --daemonize=no &
for _ in $(seq 1 20); do [ -S "$XDG_RUNTIME_DIR/pulse/native" ] && break; sleep 0.5; done
log "PulseAudio socket: $([ -S "$XDG_RUNTIME_DIR/pulse/native" ] && echo ready || echo MISSING)"

# ── 4) seatd — wlroots (sway's backend library) still initializes libseat even in
#    fully headless mode; without a running seat daemon sway fails at startup with
#    "Could not connect to socket /run/seatd.sock". Lightweight, no dbus/systemd
#    needed — just this one daemon. ──────────────────────────────────────────────
seatd -g video &
SEATD_PID=$!
for _ in $(seq 1 20); do [ -S /run/seatd.sock ] && break; sleep 0.2; done
log "seatd up (pid $SEATD_PID): $([ -S /run/seatd.sock ] && echo ready || echo MISSING)"

# ── 5) headless sway (wlroots) — WLR_BACKENDS=headless + WLR_LIBINPUT_NO_DEVICES=1
#    means no real GPU/input device is ever touched. sway itself REFUSES to start as
#    root ("Unable to drop root... refusing to start" — a hard check, not tunable via
#    flag), so it runs as the dedicated `sway-user` (Dockerfile, in the seatd -g video
#    group). root (waydroid session, later) can still open sway-user's Wayland socket
#    fine — root bypasses DAC permission checks, only sway's own EUID check cares.
#    XDG_RUNTIME_DIR must be owned by whoever connects to it AS OWNER for wlroots'
#    own runtime-dir sanity check, so it's chowned to sway-user here. ──────────────
chown sway-user:sway-user "$XDG_RUNTIME_DIR"
su -s /bin/sh sway-user -c \
  "XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 exec sway --unsupported-gpu" \
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
log "sway up (pid $SWAY_PID), wayland socket $WAYLAND_DISPLAY"

# ── 6) wayvnc — exports the headless sway output over VNC. No TLS/auth by default
#    (matches the prior RDP backend's no-app-login model); bound to all interfaces
#    inside the container, published to 127.0.0.1 only by docker run -p. ──────────
wayvnc --output=HEADLESS-1 0.0.0.0 "$VNC_PORT" > /var/log/wayvnc.log 2>&1 &
WAYVNC_PID=$!
for _ in $(seq 1 20); do
  ss -tln 2>/dev/null | grep -q ":$VNC_PORT " && break
  kill -0 "$WAYVNC_PID" 2>/dev/null || { log "wayvnc died — see /var/log/wayvnc.log"; cat /var/log/wayvnc.log; exit 1; }
  sleep 0.5
done
log "wayvnc up (pid $WAYVNC_PID), listening VNC :$VNC_PORT"

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

# Waydroid's OWN default LXC config mounts cgroup READ-ONLY for the guest
# (`lxc.mount.auto = cgroup:ro sys:ro proc`) — fine on bare metal where the host
# already owns a real cgroup hierarchy, but inside this Docker container Android's
# libprocessgroup needs to CREATE its own cgroup subtree (/sys/fs/cgroup/uid_0, one
# per app) for hwcomposer/surfaceflinger's process groups. Read-only there is a hard,
# deterministic boot failure (confirmed: every fresh boot, hwcomposer-2-1 crash-loops
# forever, surfaceflinger never starts) — patch it to rw, same class of fix as the
# iptables-legacy/xt_CHECKSUM Dockerfile patches, just applied post-init since this
# config file is only generated by `waydroid init`, not present at image build time.
if [ -f /var/lib/waydroid/lxc/waydroid/config ]; then
  sed -i 's/^lxc\.mount\.auto = cgroup:ro /lxc.mount.auto = cgroup:rw /' \
    /var/lib/waydroid/lxc/waydroid/config || true
fi

# ── 7) Waydroid container (Android's own LXC container — binder/ashmem-free vendor
#    image) then the SESSION as a Wayland CLIENT of the sway compositor started
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
log "waydroid session start issued (WAYLAND_DISPLAY=$WAYLAND_DISPLAY) — attaching as sway client"

# ── 8) PID 1 duties: stay in foreground, forward SIGTERM to a FULL, ORDERED
#    shutdown of every stack this entrypoint started. "Close the container ⇒ close
#    every stack" — nothing (wayvnc, sway, seatd, pulseaudio, either D-Bus daemon,
#    the waydroid session/container) may outlive this process. Docker's own
#    PID-namespace teardown would eventually reap stragglers on SIGKILL, but that
#    skips `waydroid session/container stop`'s graceful state flush and can corrupt
#    Android's persistent /data (the exact ghost-process class of bug that got
#    the original desktop-session Waydroid decommissioned) — so this trap does
#    the graceful stop itself, in dependency order, before returning control. ──
term_handler() {
  log "SIGTERM received — full stack teardown…"
  waydroid session stop 2>/dev/null || true
  waydroid container stop 2>/dev/null || true
  log "  waydroid session+container stopped"
  kill "$WAYVNC_PID" 2>/dev/null || true
  wait "$WAYVNC_PID" 2>/dev/null || true
  log "  wayvnc stopped"
  kill "$SWAY_PID" 2>/dev/null || true
  wait "$SWAY_PID" 2>/dev/null || true
  log "  sway stopped"
  kill "$SEATD_PID" 2>/dev/null || true
  wait "$SEATD_PID" 2>/dev/null || true
  log "  seatd stopped"
  pulseaudio --kill 2>/dev/null || true
  log "  pulseaudio stopped"
  [ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null || true
  log "  dbus session bus stopped"
  [ -n "${DBUS_SYSTEM_BUS_PID:-}" ] && kill "$DBUS_SYSTEM_BUS_PID" 2>/dev/null || true
  log "  dbus system bus stopped — teardown complete"
  exit 0
}
trap term_handler SIGTERM SIGINT

wait "$SESSION_PID" "$CONTAINER_PID" "$WAYVNC_PID"
