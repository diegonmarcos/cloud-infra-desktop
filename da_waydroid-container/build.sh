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
#   ./build.sh build   # docker build the image (Debian + waydroid + weston, baked fixes)
#   ./build.sh up      # run the container + attach xfreerdp GUI (GUI-bound, like da_redroid)
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
rd_xfreerdp() { command -v xfreerdp >/dev/null 2>&1 && { command -v xfreerdp; return; }; tool freerdp xfreerdp; }

container_name() { get container.container_name; }
container_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$(container_name)"; }
container_exists()  { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$(container_name)"; }

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
    local port; port="$(get container.rdp_port)"
    log "creating container '$(container_name)' from $img…"
    # --privileged: Waydroid needs to create its own LXC container + binderfs mount
    # inside this Docker container (nested containerization, same as bare-metal Waydroid
    # needing root). --device /dev/dri: GPU passthrough for gpu_mode=host (EGL/DRM render
    # node), matching da_redroid's approach to graphics rather than software rendering.
    docker run -d --name "$(container_name)" \
      --privileged \
      --cpus "$(cpu_cap)" \
      --device /dev/dri \
      -v "$data:/var/lib/waydroid" \
      -p "$(get container.rdp_addr):$port" \
      -e "WAYDROID_RDP_PORT=$port" \
      -e "WAYDROID_WIDTH=$(get container.width)" \
      -e "WAYDROID_HEIGHT=$(get container.height)" \
      -e "WAYDROID_GPU_MODE=$(get waydroid.gpu_mode)" \
      "$img" >/dev/null
  fi
  log "waiting for RDP port $(get container.rdp_addr)…"
  local addr port host p; addr="$(get container.rdp_addr)"; host="${addr%%:*}"; port="${addr##*:}"
  for _ in $(seq 1 60); do
    (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null && { exec 3>&-; log "RDP port open."; return 0; }
    sleep 2
  done
  warn "RDP port not reachable within 120s — the GUI may fail to connect; check: docker logs $(container_name)"
}

# _run_gui — mirrors da_redroid's GUI-bound invariant: attach xfreerdp in the
# FOREGROUND, and when the window closes, stop the container. "No GUI ⇒ no running
# waydroid-container" — the detached `docker run` is only the backend for this window.
_run_gui() {
  _ensure_running
  local xf; xf="$(rd_xfreerdp)"
  local addr; addr="$(get container.rdp_addr)"
  log "launching xfreerdp GUI on $addr…"
  "$xf" /v:"$addr" /cert:ignore /sec:tls +clipboard -wallpaper /w:"$(get container.width)" /h:"$(get container.height)" || true
  log "GUI closed — stopping waydroid-container (no GUI ⇒ no running container)…"
  cmd_down
}

cmd_up() { _run_gui; }
cmd_down() {
  container_exists || { log "container '$(container_name)' does not exist"; return 0; }
  log "stopping container '$(container_name)'…"; docker stop "$(container_name)" >/dev/null || true
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
