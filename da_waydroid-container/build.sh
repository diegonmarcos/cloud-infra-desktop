#!/usr/bin/env bash
# waydroid-container — Waydroid (official LineageOS-based, memfd-native vendor image)
# run headless inside Docker, decoupled from the live desktop Wayland session (the
# ghost-process bug that got the original desktop-session Waydroid decommissioned
# cannot recur — the container's lifecycle is independent of the desktop session).
#
# Exists because Waydroid's vendor image needs no real /dev/ashmem (memfd-native since
# 1.2.1+), unlike redroid's stock AOSP image — the target for Chromium-based browsers
# (Brave) that crash under redroid on this ashmem-less mainline-kernel host.
#
#   ./build.sh build   # docker build the image (Debian + waydroid + sway + wayvnc, baked fixes)
#   ./build.sh up      # run the container + attach VNC GUI (GUI-bound, like da_redroid)
#   ./build.sh down    # stop the container
#   ./build.sh status  # container + waydroid state
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$ROOT/build.json"
SRC="$ROOT/src"

c_g='\033[0;32m'; c_y='\033[0;33m'; c_r='\033[0;31m'; c_0='\033[0m'
log()  { printf "${c_g}[waydroid-container]${c_0} %s\n" "$*"; }
warn() { printf "${c_y}[waydroid-container]${c_0} %s\n" "$*"; }
die()  { printf "${c_r}[waydroid-container] ERROR:${c_0} %s\n" "$*" >&2; exit 1; }

get() { node -e "const c=require('$CONFIG');const v='$1'.split('.').reduce((o,k)=>o&&o[k],c);process.stdout.write(String(v??''))"; }

tool() { local b; b="$(nix build --no-link --print-out-paths "nixpkgs#$1" 2>/dev/null | head -1)/bin/$2"; [ -x "$b" ] || die "could not resolve $2 via nixpkgs#$1"; printf '%s' "$b"; }
rd_vncviewer() { command -v vncviewer >/dev/null 2>&1 && { command -v vncviewer; return; }; tool tigervnc vncviewer; }

container_name() { get container.container_name; }
container_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$(container_name)"; }
container_exists()  { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$(container_name)"; }

# VNC connect target: the container's OWN bridge IP, NOT the published
# 127.0.0.1:<port> — docker's userland-proxy mangles the RFB/VNC wire protocol on
# published ports (confirmed: raw `nc` to 127.0.0.1 never receives the RFB version
# banner at all, TCP handshake completes but zero protocol bytes arrive; the SAME
# container IP gets the banner instantly). This is the identical class of bug
# already documented for da_redroid's adb_addr() (docker-proxy mangles ADB's wire
# protocol on published ports too) — same fix: resolve the LIVE container IP.
# Falls back to the static vnc_addr from build.json before the container exists
# (early connect attempts), so nothing breaks pre-`up`.
vnc_port_internal() { get container.vnc_port; }
vnc_addr() {
  local ip; ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(container_name)" 2>/dev/null)"
  if [ -n "$ip" ]; then printf '%s:%s' "$ip" "$(vnc_port_internal)"; else get container.vnc_addr; fi
}

cpu_cap() {
  local want avail; want="$(get container.cpu_cores)"; avail="$(nproc 2>/dev/null || echo 4)"
  [ "$want" -le "$avail" ] 2>/dev/null && printf '%s' "$want" || printf '%s' "$avail"
}

cmd_build() {
  command -v docker >/dev/null 2>&1 || die "docker not found"
  local base img; base="$(get container.base_image)"; img="$(get container.image)"
  log "docker build $img (base $base)…"
  docker build --build-arg BASE="$base" -t "$img" "$SRC" || die "docker build failed"
  log "built: $img"
}

_ensure_running() {
  command -v docker >/dev/null 2>&1 || die "docker not found (NixOS: virtualisation.docker.enable)"
  if container_running; then log "container '$(container_name)' already running"; return 0; fi
  local data; data="$(get container.data_volume)"; sudo mkdir -p "$data"
  if container_exists; then
    log "starting existing container '$(container_name)'…"
    docker start "$(container_name)" >/dev/null
  else
    local img; img="$(get container.image)"
    docker image inspect "$img" >/dev/null 2>&1 || die "image $img not built — run: ./build.sh build"
    local port; port="$(get container.vnc_port)"
    log "creating container '$(container_name)' from $img…"
    # --privileged: Waydroid needs to create its own LXC container + binderfs mount
    # inside this Docker container (nested containerization, same as bare-metal Waydroid
    # needing root). --device /dev/dri: GPU passthrough (EGL/DRM render node), matching
    # da_redroid's approach to graphics rather than software rendering.
    # --memory-reservation: a SOFT limit — under host-wide memory pressure the kernel
    # prefers reclaiming from cgroups that exceed THEIR OWN reservation first, so
    # Android's system_server/zygote get priority over other, unreserved processes
    # instead of being starved (confirmed necessary: lmkd was crash-looping
    # system_server every ~5s under concurrent host memory pressure).
    # --cgroupns=host: Waydroid's nested LXC guest needs to create its OWN cgroup
    # subtree (/sys/fs/cgroup/uid_0, etc.) for hwcomposer/surfaceflinger's process
    # groups. Docker's default --cgroupns=private (since 20.10, on cgroup v2 hosts)
    # gives this container its own cgroup NAMESPACE but the nested LXC delegation
    # into a FURTHER sub-namespace then hits "Read-only file system" deterministically
    # (confirmed: 2 independent fresh-container boots, same failure every time,
    # crash-looping surfaceflinger forever) — sharing the host's cgroup namespace
    # gives genuine top-level write access matching what --privileged implies but
    # doesn't fully grant under the private cgroupns default.
    docker run -d --name "$(container_name)" \
      --privileged \
      --cgroupns=host \
      --cpus "$(cpu_cap)" \
      --memory-reservation "$(get container.memory_reservation)" \
      --device /dev/dri \
      -v "$data:/var/lib/waydroid" \
      -p "$(get container.vnc_addr):$port" \
      -e "WAYDROID_VNC_PORT=$port" \
      -e "WAYDROID_WIDTH=$(get container.width)" \
      -e "WAYDROID_HEIGHT=$(get container.height)" \
      "$img" >/dev/null
  fi
  log "waiting for VNC (container bridge IP)…"
  local addr host port; addr="$(vnc_addr)"; host="${addr%%:*}"; port="${addr##*:}"
  for _ in $(seq 1 60); do
    (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null && { exec 3>&-; log "VNC port open at $addr."; return 0; }
    sleep 2
  done
  warn "VNC port not reachable within 120s — the GUI may fail to connect; check: docker logs $(container_name)"
}

# _run_gui — mirrors da_redroid's GUI-bound invariant: attach vncviewer in the
# FOREGROUND, and when the window closes, stop the container. "No GUI ⇒ no running
# waydroid-container" — the detached `docker run` is only the backend for this window.
_run_gui() {
  _ensure_running
  local vv; vv="$(rd_vncviewer)"
  local addr; addr="$(vnc_addr)"
  log "launching vncviewer GUI on $addr…"
  "$vv" "$addr" || true
  log "GUI closed — stopping waydroid-container (no GUI ⇒ no running container)…"
  cmd_down
}

cmd_up() { _run_gui; }
# down — full stack teardown. Uses the data-driven stop_timeout_seconds (not
# docker's 10s default) so the entrypoint's ordered SIGTERM trap (waydroid
# session/container -> wayvnc -> sway -> seatd -> pulseaudio -> dbus) actually completes before
# docker escalates to SIGKILL, then VERIFIES the container is truly gone rather
# than firing docker stop and trusting it — "close the container closes every
# stack" is a guarantee, not a best-effort.
cmd_down() {
  container_exists || { log "container '$(container_name)' does not exist"; return 0; }
  local t; t="$(get container.stop_timeout_seconds)"
  log "stopping container '$(container_name)' (up to ${t}s for a clean stack teardown)…"
  docker stop -t "$t" "$(container_name)" >/dev/null || true
  if container_running; then
    warn "container still running after ${t}s graceful window — forcing stop"
    docker kill "$(container_name)" >/dev/null 2>&1 || true
  fi
  container_running && die "failed to stop '$(container_name)' — a stack may still be running"
  log "stopped."
}
cmd_status() {
  printf "Container: "; container_running && echo "RUNNING ($(container_name))" || { container_exists && echo "stopped" || echo "not created"; }
  container_running && { echo "--- waydroid status ---"; docker exec "$(container_name)" waydroid status 2>&1 || true; }
}

case "${1:-up}" in
  build)  cmd_build ;;
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  *) die "unknown command '$1'
  build | up | down | status" ;;
esac
