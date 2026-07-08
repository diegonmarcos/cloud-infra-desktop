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

# Config source of truth. In the repo this reads build.json; the self-contained
# `bundle` artifact (src/waydroid-launcher, baked into the GHCR image at
# /opt/launcher/waydroid) has BUNDLED_CONFIG_B64 replaced with build.json as base64,
# so the portable binary needs neither the repo nor build.json beside it — only
# docker + bash + node. Regenerated FROM build.json on every build (the dist/ artifact
# pattern), never hand-edited: build.json stays the single source of truth.
BUNDLED_CONFIG_B64=''
_config_json() { if [ -n "$BUNDLED_CONFIG_B64" ]; then printf '%s' "$BUNDLED_CONFIG_B64" | base64 -d; else cat "$CONFIG"; fi; }
get() { _config_json | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const c=JSON.parse(s);const v=process.argv[1].split('.').reduce((o,k)=>o&&o[k],c);process.stdout.write(String(v??''))})" "$1"; }
# get_array <dotted.path> — echoes a JSON string array joined by spaces.
get_array() { _config_json | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const c=JSON.parse(s);const v=process.argv[1].split('.').reduce((o,k)=>o&&o[k],c);process.stdout.write((v||[]).join(' '))})" "$1"; }

tool() { local b; b="$(nix build --no-link --print-out-paths "nixpkgs#$1" 2>/dev/null | head -1)/bin/$2"; [ -x "$b" ] || die "could not resolve $2 via nixpkgs#$1"; printf '%s' "$b"; }
rd_vncviewer()  { command -v vncviewer >/dev/null 2>&1 && { command -v vncviewer; return; }; tool tigervnc vncviewer; }
rd_moonlight()  { command -v moonlight >/dev/null 2>&1 && { command -v moonlight; return; }; tool moonlight-qt moonlight; }

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
  docker build --build-arg BASE="$base" \
    --build-arg SUNSHINE_DEB_URL="$(get stream.sunshine_deb_url)" \
    --build-arg SUNSHINE_DEB_SHA256="$(get stream.sunshine_deb_sha256)" \
    -t "$img" "$SRC" || die "docker build failed"
  # Reclaim the PREVIOUS image generation: every rebuild retags $img and orphans the
  # prior multi-GB layer stack as dangling. Left alone, an iteration loop fills the
  # Docker data-root partition — confirmed 2026-07-08: repeated rebuilds drove
  # /mnt/shared-lib to 99%, tripping the disk-emergency guard whose workload.slice
  # FREEZE halted the whole desktop (perceived as a total system freeze). Dangling-
  # only prune: tagged images and volumes are never touched.
  docker image prune -f >/dev/null 2>&1 || true
  log "built: $img (previous dangling generation pruned)"
}

# _ensure_running <mode> — start (or create) the container for the given display
# mode. A container created for one mode carries that mode in its env for its whole
# life — if the requested mode differs from the existing container's, it is recreated
# (the /data volume persists, so Android state survives).
_ensure_running() {
  local mode="$1"
  command -v docker >/dev/null 2>&1 || die "docker not found (NixOS: virtualisation.docker.enable)"
  if container_exists; then
    local cur_mode
    cur_mode="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(container_name)" 2>/dev/null | command grep '^WAYDROID_DISPLAY_MODE=' | cut -d= -f2)"
    if [ "${cur_mode:-}" != "$mode" ]; then
      log "existing container is mode '${cur_mode:-unknown}', requested '$mode' — recreating (Android /data persists)…"
      docker rm -f "$(container_name)" >/dev/null 2>&1 || true
    fi
  fi
  if container_running; then log "container '$(container_name)' already running"; return 0; fi
  local data; data="$(get container.data_volume)"; sudo mkdir -p "$data"
  if container_exists; then
    log "starting existing container '$(container_name)'…"
    docker start "$(container_name)" >/dev/null
  else
    local img; img="$(get container.image)"
    # Pull-first: the image is BUILT IN GHA and published to GHCR (ship_waydroid-container
    # workflow) — a machine that never ran `./build.sh build` locally just pulls the
    # released image. Local build stays available for development iteration.
    docker image inspect "$img" >/dev/null 2>&1 || {
      log "image $img not present locally — pulling from GHCR…"
      docker pull "$img" || die "image $img neither built locally nor pullable — run: ./build.sh build"
    }
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
    # -v /run/udev:ro — Moonlight input path: Sunshine injects input by creating
    # virtual uinput devices; sway's libinput backend discovers devices through
    # LIBUDEV, and this container runs no udevd — without the host's udev runtime
    # shared in, the virtual mouse/keyboard/touch devices are created but NEVER
    # seen by the compositor (confirmed live: /dev/uinput + event nodes present,
    # sway log zero libinput device lines, no input working in the stream). The
    # host's udevd processes the uevents; sharing its /run/udev database+monitor
    # socket read-only is the standard Sunshine-in-docker input wiring.
    # native mode: the HOST's XDG_RUNTIME_DIR (KDE's wayland + pulse sockets) is
    # bind-mounted at /host-xdg — Waydroid's hwcomposer becomes a direct Wayland
    # client of the host compositor (the exact bare-metal Waydroid-on-KDE wiring).
    local native_mounts=()
    if [ "$mode" = "native" ]; then
      [ -n "${XDG_RUNTIME_DIR:-}" ] || die "native mode needs \$XDG_RUNTIME_DIR (run from a desktop session)"
      native_mounts=(-v "$XDG_RUNTIME_DIR:/host-xdg")
    fi
    docker run -d --name "$(container_name)" \
      --privileged \
      --cgroupns=host \
      --cpus "$(cpu_cap)" \
      --memory-reservation "$(get container.memory_reservation)" \
      --device /dev/dri \
      -v /run/udev:/run/udev:ro \
      -v "$data:/var/lib/waydroid" \
      "${native_mounts[@]}" \
      -p "$(get container.vnc_addr):$port" \
      -e "WAYDROID_DISPLAY_MODE=$mode" \
      -e "WAYDROID_HOST_WAYLAND_DISPLAY=$(get display.host_wayland_display)" \
      -e "WAYDROID_VNC_PORT=$port" \
      -e "WAYDROID_WIDTH=$(get container.width)" \
      -e "WAYDROID_HEIGHT=$(get container.height)" \
      "$img" >/dev/null
  fi
  if [ "$mode" = "native" ]; then
    log "waiting for the waydroid session (native window on the host desktop)…"
    for _ in $(seq 1 90); do
      docker exec "$(container_name)" waydroid status 2>/dev/null | grep -q "Session:.*RUNNING" && { log "session RUNNING."; return 0; }
      sleep 2
    done
    warn "session not RUNNING within 180s — check: docker logs $(container_name)"
    return 0
  fi
  log "waiting for VNC (container bridge IP)…"
  local addr host port; addr="$(vnc_addr)"; host="${addr%%:*}"; port="${addr##*:}"
  for _ in $(seq 1 60); do
    (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null && { exec 3>&-; log "VNC port open at $addr."; return 0; }
    sleep 2
  done
  warn "VNC port not reachable within 120s — the GUI may fail to connect; check: docker logs $(container_name)"
}

container_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(container_name)" 2>/dev/null; }

# _pair_moonlight — one-time automated Sunshine<->Moonlight pairing (persists on the
# data volume). We CHOOSE the 4-digit PIN, hand it to `moonlight pair --pin` and POST
# the same PIN to Sunshine's /api/pin with the container-generated web credentials —
# no interactive browser step, fully scripted.
_pair_moonlight() {
  local ml="$1" ip="$2"
  "$ml" list "$ip" 2>/dev/null | grep -q . && return 0
  local pass pin
  pass="$(docker exec "$(container_name)" cat /var/lib/waydroid/sunshine/web-pass 2>/dev/null)" \
    || die "cannot read sunshine web credentials from the container"
  pin="$(od -An -N2 -i /dev/urandom | tr -d ' ')"; pin="$(( (pin % 9000) + 1000 ))"
  log "pairing Moonlight with Sunshine (one-time, PIN $pin)…"
  "$ml" pair "$ip" --pin "$pin" > /tmp/moonlight-pair.log 2>&1 &
  local pair_pid=$!
  local ok=""
  for _ in $(seq 1 20); do
    sleep 1
    if curl -sk -u "admin:$pass" -X POST "https://$ip:47990/api/pin" \
         -H 'Content-Type: application/json' \
         -d "{\"pin\":\"$pin\",\"name\":\"$(hostname)\"}" 2>/dev/null | grep -q '"status":.*true'; then
      ok=1; break
    fi
  done
  wait "$pair_pid" 2>/dev/null || true
  [ -n "$ok" ] || die "Sunshine PIN submission failed — see /tmp/moonlight-pair.log and: docker exec $(container_name) cat /var/log/sunshine.log"
  log "paired."
}

# _run_gui — GUI-bound invariant: keep a GUI in the FOREGROUND, and when it closes,
# stop the container. "No GUI ⇒ no running waydroid-container".
#   (default) native: Android IS a native window on the host desktop (one cursor,
#             native touch, native audio, no stream). This engine call blocks while
#             the window exists and tears the container down when it closes.
#   stream:   Moonlight window (Sunshine VAAPI stream — remote-desktop UX).
#   vnc:      TigerVNC window (debug transport).
_run_gui() {
  local mode="${1:-$(get display.mode)}"
  _ensure_running "$mode"
  case "$mode" in
    native)
      # KDE Plasma 6 is WAYLAND: the Waydroid window is a native Wayland toplevel of the
      # host compositor, NOT an X11 window — xdotool/xprop/wmctrl cannot see it (that was
      # the earlier false-negative "window never appeared" while it was plainly on screen).
      # So the lifecycle is NOT bound to window polling. Native mode is a normal desktop
      # app: `up` brings Android up (the entrypoint already ran show-full-ui once), we
      # re-issue show-full-ui so a re-run re-shows a closed/hidden window, then RETURN —
      # the window persists like any app. Closing it hides Android (it stays booted, the
      # desktop-natural behavior, unlike the stream/vnc teardown-on-close); `down` stops
      # the container. This return skips the cmd_down at the end of _run_gui.
      docker exec -d "$(container_name)" waydroid show-full-ui 2>/dev/null || true
      log "Waydroid is now a NATIVE window on your desktop — one cursor, native touch/trackpad/audio."
      log "  re-show: waydroid up   ·   stop: waydroid down   ·   status: waydroid status"
      return 0
      ;;
    vnc)
      local vv; vv="$(rd_vncviewer)"
      log "launching vncviewer (debug transport) on $(vnc_addr)…"
      "$vv" "$(vnc_addr)" || true
      ;;
    stream)
      local ip; ip="$(container_ip)"
      local ml; ml="$(rd_moonlight)"
      for _ in $(seq 1 30); do
        curl -sk "https://$ip:47990" >/dev/null 2>&1 && break
        sleep 1
      done
      _pair_moonlight "$ml" "$ip"
      local res fps flags; res="$(get container.width)x$(get container.height)"; fps="$(get stream.fps)"
      flags="$(get_array stream.client_flags)"
      log "launching Moonlight stream ($res@${fps}fps, VAAPI GPU pipeline, windowed) on $ip…"
      # shellcheck disable=SC2086 — flags is a flat list of CLI switches by design
      "$ml" stream "$ip" "$(get stream.app_name)" --resolution "$res" --fps "$fps" --quit-after $flags || true
      ;;
    *) die "unknown display mode '$mode' (native | stream | vnc)" ;;
  esac
  log "GUI closed — stopping waydroid-container (no GUI ⇒ no running container)…"
  cmd_down
}

cmd_up() { _run_gui "${1:-}"; }
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

# test — the tester (a fix is not done until this passes). Verifies the WHOLE display
# pipeline with EVIDENCE, not assumptions:
#   1. Android reached boot_completed=1
#   2. sway's window tree has an actual mapped client surface (the Waydroid UI) —
#      the exact failure mode that shipped a blank screen before was "Android boots,
#      compositor tree empty" (missing show-full-ui)
#   3. grim captures the compositor's REAL composited output (the same pixels wayvnc
#      serves) and it is a non-trivial image, not a blank frame
#   4. the VNC server answers with an RFB banner on the container's own bridge IP
cmd_test() {
  local name fail=0; name="$(container_name)"
  container_running || die "container not running — run: ./build.sh up"
  local mode
  mode="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null | command grep '^WAYDROID_DISPLAY_MODE=' | cut -d= -f2)"
  log "testing display mode: ${mode:-unknown}"

  printf "1. boot_completed: "
  local bc; bc="$(docker exec "$name" waydroid shell -- getprop sys.boot_completed 2>/dev/null | tr -d '[:space:]')"
  [ "$bc" = "1" ] && echo "OK" || { echo "FAIL (got '$bc')"; fail=1; }

  if [ "$mode" = "native" ]; then
    # Wayland-safe checks only — no X11 window tools (they can't see the native
    # Wayland toplevel). Session RUNNING = hwcomposer attached to the host compositor
    # (the window is up); non-blank screencap = Android is actually rendering into it.
    printf "2. waydroid session attached to host compositor: "
    docker exec "$name" waydroid status 2>/dev/null | grep -q "Session:.*RUNNING" && echo "OK" \
      || { echo "FAIL (session not RUNNING)"; fail=1; }

    printf "3. Android actually rendering (screencap non-blank): "
    local sz
    docker exec "$name" waydroid shell -- screencap -p /data/local/tmp/t.png >/dev/null 2>&1
    sz="$(docker exec "$name" stat -c %s /root/.local/share/waydroid/data/local/tmp/t.png 2>/dev/null || echo 0)"
    if [ "${sz:-0}" -gt 20000 ] 2>/dev/null; then echo "OK (${sz} bytes)"
    else echo "FAIL (screencap ${sz:-0} bytes — likely blank)"; fail=1; fi

    printf "4. host wayland socket mounted (native-mode wiring): "
    docker exec "$name" sh -c '[ -S /host-xdg/$WAYDROID_HOST_WAYLAND_DISPLAY ]' 2>/dev/null && echo "OK" \
      || { echo "FAIL (host compositor socket not bind-mounted)"; fail=1; }

    [ "$fail" = 0 ] && log "ALL TESTS PASSED — native window pipeline verified" || die "pipeline test FAILED"
    return 0
  fi

  printf "2. UI surface mapped in sway: "
  local sock; sock="$(docker exec "$name" sh -c "find \$XDG_RUNTIME_DIR -maxdepth 1 -name 'sway-ipc.*.sock' | head -1")"
  if docker exec "$name" su -s /bin/sh sway-user -c "SWAYSOCK='$sock' swaymsg -t get_tree" 2>/dev/null | grep -q '"shell": "xdg_shell"'; then
    echo "OK"
  else echo "FAIL (compositor tree has no client — blank desktop)"; fail=1; fi

  printf "3. composited frame non-blank: "
  local px
  px="$(docker exec "$name" su -s /bin/sh sway-user -c "SWAYSOCK='$sock' XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR WAYLAND_DISPLAY=\$(basename \$(find \$XDG_RUNTIME_DIR -maxdepth 1 -name 'wayland-*' ! -name '*.lock' | head -1)) grim -o HEADLESS-1 /tmp/frame.png && stat -c %s /tmp/frame.png" 2>/dev/null | tail -1)"
  if [ -n "$px" ] && [ "$px" -gt 20000 ] 2>/dev/null; then echo "OK (${px} bytes)"
  else echo "FAIL (frame ${px:-unreadable} bytes — likely blank)"; fail=1; fi

  printf "4. VNC RFB banner (fallback transport): "
  local addr host port; addr="$(vnc_addr)"; host="${addr%%:*}"; port="${addr##*:}"
  if timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port; head -c 3 <&3" 2>/dev/null | grep -q RFB; then
    echo "OK ($addr)"
  else echo "FAIL (no RFB banner at $addr)"; fail=1; fi

  printf "5. Sunshine web API up (primary transport): "
  local sip; sip="$(container_ip)"
  if curl -sk -o /dev/null -w '%{http_code}' "https://$sip:47990" 2>/dev/null | grep -qE '^(200|401)$'; then
    echo "OK (https://$sip:47990)"
  else echo "FAIL (Sunshine web UI unreachable)"; fail=1; fi

  printf "6. Sunshine VAAPI hardware encoder: "
  if docker exec "$name" sh -c 'command grep -qiE "vaapi|va_" /var/log/sunshine.log && ! command grep -qi "fail" /var/log/sunshine.log' 2>/dev/null; then
    echo "OK"
  else
    docker exec "$name" sh -c 'command grep -qi "software" /var/log/sunshine.log' 2>/dev/null \
      && { echo "FAIL (fell back to software encoding)"; fail=1; } \
      || echo "SKIP (no encoder line yet — encoder initializes on first stream)"
  fi

  printf "7. input devices reach the compositor: "
  if docker exec "$name" sh -c 'command grep -q "CLIENT CONNECTED" /var/log/sunshine.log' 2>/dev/null; then
    if docker exec "$name" su -s /bin/sh sway-user -c "SWAYSOCK='$sock' swaymsg -t get_inputs" 2>/dev/null | grep -q '"identifier"'; then
      echo "OK"
    else echo "FAIL (stream active but sway sees no input devices — mouse/touch dead)"; fail=1; fi
  else echo "SKIP (no active Moonlight stream — devices are created on connect)"; fi

  [ "$fail" = 0 ] && log "ALL TESTS PASSED — the GUI pipeline is verifiably rendering" || die "pipeline test FAILED"
}

# push — publish the built image to GHCR (CI path: the ship-waydroid-container GHA
# workflow builds + pushes on every da_waydroid-container/** change to main; runtime
# machines then just `docker pull` — see the pull-first logic in _ensure_running).
cmd_push() {
  local img; img="$(get container.image)"
  docker image inspect "$img" >/dev/null 2>&1 || die "image $img not built — run: ./build.sh build"
  log "pushing $img to GHCR…"
  docker push "$img" || die "docker push failed (are you logged in to ghcr.io?)"
  log "pushed."
}

case "${1:-up}" in
  build)  cmd_build ;;
  up)     cmd_up "${2:-}" ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  test)   cmd_test ;;
  push)   cmd_push ;;
  *) die "unknown command '$1'
  build | up [native|stream|vnc] | down | status | test | push" ;;
esac
