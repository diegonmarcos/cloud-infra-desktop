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
# Two display modes (build.json display.mode, default native):
#   native  — Android is a NATIVE KDE window (host Wayland socket bind-mounted in;
#             one cursor, native touch/trackpad/audio, no stream). The seamless UX.
#   stream  — headless sway + Sunshine VAAPI encode → Moonlight (remote-desktop UX).
#   vnc     — headless sway → wayvnc → TigerVNC (debug transport).
#
#   ./build.sh build            # bundle + apps-fetch + docker build (apps/launcher/theme baked in)
#   ./build.sh bundle           # (re)generate the self-contained launcher from build.json
#   ./build.sh apps-fetch       # reproducibly fetch the pinned APK set (build.json apps.list) into src/apks/
#   ./build.sh bake             # boot+provision a scratch container, snapshot /data, bake it into the image (LOCAL-only: needs binder)
#   ./build.sh install [bindir] # pull the GHCR image, copy the baked launcher into a bin dir
#   ./build.sh up [native|stream|vnc]   # bring the container up + open the GUI (default native)
#   ./build.sh down             # stop the container
#   ./build.sh status           # container + waydroid state
#   ./build.sh test             # evidence-based pipeline tester
#   ./build.sh push             # push the image to GHCR (CI path)
#
# The `install`-produced binary is fully self-contained (build.json baked in as
# base64) — it needs docker+bash+node but NO repo and NO build.json beside it.
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
# kdotool — xdotool for KWin/Wayland (Plasma 6). The only way to see the native
# Waydroid Wayland toplevel (X11 tools can't). Optional: if absent, native close-to-
# stop is disabled and the container is stopped with `waydroid down` instead.
rd_kdotool()    { command -v kdotool  >/dev/null 2>&1 && { command -v kdotool;  return; }; tool kdotool kdotool; }

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

# bundle — generate the self-contained launcher (src/waydroid-launcher): this very
# engine with build.json baked in as base64 (BUNDLED_CONFIG_B64), so it runs with no
# repo and no build.json beside it. Emitted into the docker BUILD CONTEXT (src/) so
# the Dockerfile can COPY it into the image at /opt/launcher/waydroid → it ships to
# GHCR, and `install` extracts it to a bin dir. gitignored (generated artifact).
cmd_bundle() {
  command -v base64 >/dev/null 2>&1 || die "base64 not found"
  local out="$SRC/waydroid-launcher" b64
  b64="$(base64 -w0 "$CONFIG")"          # base64 alphabet is sed-`|`-delimiter-safe
  sed "s|^BUNDLED_CONFIG_B64=''|BUNDLED_CONFIG_B64='$b64'|" "$ROOT/build.sh" > "$out"
  chmod +x "$out"
  log "bundled self-contained launcher: $out ($(wc -c <"$out") bytes)"
}

# apps-lock [pkg...] — (re)resolve pinned versionCode/sha256 for build.json's
# apps.list into src/apps/apps.lock.json (ported from da_waydroid-apps' cmd_lock).
# No args = full relock of every fdroid/github-sourced app; args = surgical relock of
# just those packages, merged into the existing lockfile (e.g. when a `latest`-tagged
# GitHub release moves forward and its pinned sha256 goes stale — apps-fetch fails
# LOUDLY with a hash mismatch in that case, by design; this is the fix).
cmd_apps_lock() {
  local lockfile="$SRC/apps/apps.lock.json"
  local -a filter=( "$@" )
  local tmp; tmp="$(mktemp)"
  if [ "${#filter[@]}" -gt 0 ] && [ -f "$lockfile" ]; then
    log "relocking ${#filter[@]} package(s): ${filter[*]}"
    cp -f "$lockfile" "$tmp"
  else
    filter=()
    log "resolving F-Droid/GitHub versions + hashes for the full app set…"
    echo '{"_doc":"GENERATED by build.sh apps-lock — do not edit by hand.","apps":[]}' > "$tmp"
  fi
  local n; n="$(_config_json | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(String(JSON.parse(s).apps.list.length)))")"
  local i pkg stype
  for ((i = 0; i < n; i++)); do
    pkg="$(_config_json | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(JSON.parse(s).apps.list[$i].package))")"
    if [ "${#filter[@]}" -gt 0 ]; then
      local matched=0 f
      for f in "${filter[@]}"; do [ "$f" = "$pkg" ] && matched=1; done
      [ "$matched" = 1 ] || continue
    fi
    stype="$(_config_json | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(JSON.parse(s).apps.list[$i].source.type))")"
    case "$stype" in
      fdroid)
        local vc url pref sha
        vc="$(curl -fsSL "https://f-droid.org/api/v1/packages/$pkg" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>process.stdout.write(String(JSON.parse(d).suggestedVersionCode)))')"
        [ -n "$vc" ] && [ "$vc" != "undefined" ] || die "could not resolve suggestedVersionCode for $pkg"
        url="https://f-droid.org/repo/${pkg}_${vc}.apk"
        log "  $pkg -> versionCode $vc ; prefetching…"
        pref="$(nix store prefetch-file --json "$url")"
        sha="$(printf '%s' "$pref" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>process.stdout.write(JSON.parse(d).hash))')"
        node -e "const fs=require('fs');const f='$tmp';const o=JSON.parse(fs.readFileSync(f));o.apps=o.apps.filter(a=>a.package!=='$pkg');o.apps.push({package:'$pkg',source:'fdroid',versionCode:$vc,url:'$url',sha256:'$sha'});fs.writeFileSync(f,JSON.stringify(o,null,2));"
        ;;
      github)
        local gurl sha
        gurl="$(_config_json | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(JSON.parse(s).apps.list[$i].source.url||''))")"
        [ -n "$gurl" ] || die "github source for $pkg has no url in build.json"
        log "  $pkg -> github ; prefetching…"
        sha="$(nix store prefetch-file --json "$gurl" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>process.stdout.write(JSON.parse(d).hash))')"
        node -e "const fs=require('fs');const f='$tmp';const o=JSON.parse(fs.readFileSync(f));o.apps=o.apps.filter(a=>a.package!=='$pkg');o.apps.push({package:'$pkg',source:'github',url:'$gurl',sha256:'$sha'});fs.writeFileSync(f,JSON.stringify(o,null,2));"
        ;;
      *) die "unknown source.type '$stype' for $pkg" ;;
    esac
  done
  mv "$tmp" "$lockfile"
  log "lockfile written: $lockfile"
}

# apps-fetch — reproducibly fetch the FULL pinned APK set (build.json apps.list) into
# the docker BUILD CONTEXT so the Dockerfile can bake them into the image at
# /opt/apps/<pkg>.apk. Sourced from src/apps/flake.nix + src/apps/apps.lock.json
# (ported verbatim from the decommissioned da_waydroid-apps project — pinned
# versionCode + SRI sha256 per app, ported from apps.lock.json to a nix
# fetchurl-per-app derivation, so the output is byte-reproducible and network-only
# touches the pinned, hashed URLs). `local`-source apps have no lockfile entry and
# are skipped by the flake by design (none currently declared; all core apps are
# `github`-sourced with pinned hashes like everything else).
cmd_apps_fetch() {
  command -v nix >/dev/null 2>&1 || die "nix not found"
  # stderr (build progress) must NOT be merged into the captured path — nix build's
  # ONLY stdout is the final store path (via --print-out-paths); merging 2>&1 into the
  # capture corrupted $out with the whole progress log and broke the cp below
  # ("File name too long" — confirmed live, fixed here).
  local out; out="$(nix build "path:$SRC/apps#apks" --no-link --print-out-paths)" \
    || die "nix build of the pinned APK set failed (see output above)"
  rm -rf "$SRC/apks"; mkdir -p "$SRC/apks"
  cp -f "$out"/apks/*.apk "$SRC/apks/"
  log "fetched $(ls "$SRC/apks" | wc -l) pinned APK(s) into src/apks/ (reproducible, sha256-pinned)"
}

# bake — "the default image baked WITH our configs". Boot a throwaway container on a
# scratch volume, let it fully provision (waydroid init + install all apps + seed
# layout/theme), snapshot the ENTIRE provisioned /var/lib/waydroid, bake that snapshot
# into the image, and push. Result: the FIRST launch of the baked image restores the
# snapshot and is INSTANTLY at the curated home screen — no init download, no per-app
# install, no layout pass at runtime.
#
# LOCAL-ONLY: baking must boot Android (needs the binder kernel module), which GitHub
# CI runners do not have — so the CI ship-waydroid-container workflow builds only the
# BASE image (empty seed → runtime provisioning fallback), and this `bake` runs on a
# real host and pushes the fast image itself.
cmd_bake() {
  command -v docker >/dev/null 2>&1 || die "docker not found"
  command -v zstd   >/dev/null 2>&1 || die "zstd not found (nix profile / systemPackages)"
  local img bakevol seed; img="$(get container.image)"
  seed="$SRC/data-seed.tar.zst"
  # CRITICAL: the bake container must PROVISION FROM SCRATCH — so the base image it
  # boots must carry an EMPTY seed. If a prior (or stale) seed were baked in, the bake
  # container would restore it and skip provisioning, snapshotting nothing new. Empty
  # the seed BEFORE the base build so the bake boot goes down the runtime-provision path.
  : > "$seed"
  cmd_build   # base image with apps in /opt/apps + the now-EMPTY seed placeholder
  bakevol="$(mktemp -d /mnt/shared-lib/waydroid-bake.XXXXXX)"
  log "bake: booting a throwaway container on a scratch volume to provision…"
  docker rm -f waydroid-bake >/dev/null 2>&1 || true
  # stream mode: self-contained (nested sway) — no host Wayland dep, so bake works
  # headless / on any host. The provisioning pass is identical regardless of mode.
  docker run -d --name waydroid-bake \
    --privileged --cgroupns=host \
    --cpus "$(cpu_cap)" --memory-reservation "$(get container.memory_reservation)" \
    --device /dev/dri -v /run/udev:/run/udev:ro \
    -v "$bakevol:/var/lib/waydroid" \
    -e WAYDROID_DISPLAY_MODE=stream \
    -e "WAYDROID_WIDTH=$(get container.width)" -e "WAYDROID_HEIGHT=$(get container.height)" \
    "$img" >/dev/null || { rm -rf "$bakevol"; die "bake container failed to start"; }
  log "bake: waiting for full provisioning (init + install all apps + layout — several minutes)…"
  local ok=""
  for _ in $(seq 1 240); do   # up to ~40min (first-boot init download + 54 pm installs)
    docker exec waydroid-bake test -f /var/lib/waydroid/.apps-provisioned 2>/dev/null && { ok=1; break; }
    docker ps --format '{{.Names}}' | grep -qx waydroid-bake || { rm -rf "$bakevol"; die "bake container died — check: docker logs waydroid-bake"; }
    sleep 10
  done
  [ -n "$ok" ] || { docker rm -f waydroid-bake >/dev/null 2>&1; rm -rf "$bakevol"; die "provisioning did not finish in time"; }
  log "bake: provisioned — graceful stop to flush Android /data…"
  docker stop -t "$(get container.stop_timeout_seconds)" waydroid-bake >/dev/null 2>&1 || true
  docker rm -f waydroid-bake >/dev/null 2>&1 || true
  log "bake: snapshotting provisioned /var/lib/waydroid → seed (zstd)…"
  # --numeric-owner: Android uids/gids are numeric and must be preserved verbatim on
  # restore (the entrypoint extracts with --numeric-owner too). Run tar as root: the
  # provisioned tree is owned by container-internal Android uids the host doesn't map.
  sudo tar -C "$bakevol" --numeric-owner -cf - . | zstd -3 -T0 -o "$seed" -f
  sudo chown "$USER" "$seed"
  sudo rm -rf "$bakevol"
  log "bake: seed is $(du -h "$seed" | cut -f1) — rebuilding image WITH the seed baked in…"
  # reseal via _docker_build_image (NOT cmd_build): the context (apks/bundle/build.json)
  # is already staged from the first cmd_build; re-running apps-fetch here would
  # needlessly re-hit the network and could hash-mismatch on a moved `latest` tag,
  # breaking the reseal AFTER the expensive provision+snapshot already succeeded.
  _docker_build_image
  log "bake: complete. Push with: ./build.sh push  (then 'up' on any host is instant)"
}

# reseal — bake the ALREADY-STAGED seed (src/data-seed.tar.zst, produced by a prior
# `bake` whose provision+snapshot succeeded) into the image, without re-provisioning.
# Recovery path for a bake whose expensive snapshot completed but whose reseal build
# failed (e.g. a moved `latest` tag). Reuses the staged context verbatim.
cmd_reseal() {
  command -v docker >/dev/null 2>&1 || die "docker not found"
  [ -s "$SRC/data-seed.tar.zst" ] || die "no staged seed at $SRC/data-seed.tar.zst — run: ./build.sh bake"
  log "reseal: baking staged seed ($(du -h "$SRC/data-seed.tar.zst" | cut -f1)) into the image…"
  _docker_build_image
  log "reseal: complete. Push with: ./build.sh push"
}

# install — the "pull it to copy into a linux bin" step. Pull the GHCR image, extract
# the baked launcher (the CI build ran `bundle`, the Dockerfile copied it in), and drop
# it at <bindir>/waydroid (default ~/.local/bin). No container is run — docker cp from
# a throwaway `docker create`.
cmd_install() {
  command -v docker >/dev/null 2>&1 || die "docker not found"
  local img bindir dest; img="$(get container.image)"
  bindir="${1:-$HOME/.local/bin}"; dest="$bindir/waydroid"
  mkdir -p "$bindir"
  docker image inspect "$img" >/dev/null 2>&1 || { log "pulling $img from GHCR…"; docker pull "$img" || die "pull failed"; }
  local cid; cid="$(docker create "$img")" || die "docker create failed"
  docker cp "$cid:/opt/launcher/waydroid" "$dest" || { docker rm -f "$cid" >/dev/null 2>&1; die "extract failed — was the image built with a bundled launcher?"; }
  docker rm -f "$cid" >/dev/null 2>&1 || true
  chmod +x "$dest"
  log "installed self-contained launcher: $dest"
  case ":$PATH:" in *":$bindir:"*) : ;; *) warn "$bindir is not on \$PATH — add it, or run $dest directly";; esac
}

# _docker_build_image — the docker-build step ONLY (assumes the build context in src/
# is already staged: launcher bundle, apks, build.json, seed). Shared by cmd_build and
# cmd_bake's reseal so the reseal does NOT redundantly re-run apps-fetch (which, with a
# rolling `latest` GitHub release, can hash-mismatch mid-bake and break the reseal —
# confirmed live: the seed was already built when the reseal's re-fetch failed).
_docker_build_image() {
  # Seed placeholder: the Dockerfile always COPYs data-seed.tar.zst; a plain build
  # leaves an EMPTY one (→ runtime provisioning); bake fills it before reseal. Never
  # clobber an existing (baked) seed — only create the placeholder when none exists.
  [ -f "$SRC/data-seed.tar.zst" ] || : > "$SRC/data-seed.tar.zst"
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
  # Also prune the BUILD CACHE (buildkit layers). Dangling-image prune does NOT
  # touch it, and it accumulates GBs across rebuilds — confirmed 2026-07-10:
  # ~16GB of build cache drove /mnt/shared-lib to 97% and froze the desktop
  # (the disk-emergency reclaim couldn't self-heal because nothing pruned it).
  # Build cache is never referenced by a running container, so -af is safe.
  docker builder prune -af >/dev/null 2>&1 || true
  log "built: $img (previous dangling generation + build cache pruned)"
}

cmd_build() {
  command -v docker >/dev/null 2>&1 || die "docker not found"
  cmd_bundle          # regenerate the baked launcher from build.json before the image build
  cmd_apps_fetch      # fetch the pinned APK set into src/apks/ for the Dockerfile to COPY
  # build.json itself must be INSIDE the docker build context (src/) for the Dockerfile
  # to COPY it in — entrypoint.sh reads it at runtime (jq) to drive app provisioning
  # (apps/launcher/theme), same "regenerate a build-context artifact" pattern as
  # bundle/apps-fetch. Gitignored — build.json in the repo root stays the one source.
  cp -f "$CONFIG" "$SRC/build.json"
  _docker_build_image
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
    # :13 is a ROLLING tag (retagged on every ship, not a fresh version number) — a
    # `docker pull` after a new ship leaves the OLD container's bound image ID stale
    # even though `docker image inspect` on the tag now resolves to a different Id.
    # Without this check, a pulled-but-unused new image silently never takes effect:
    # `container_exists` stays true forever and every `up` just `docker start`s the
    # old container on the old image (discovered 2026-08-22 — a fresh ship+pull+switch
    # left the running app on a container still bound to yesterday's image).
    local cur_img new_img
    cur_img="$(docker inspect -f '{{.Image}}' "$(container_name)" 2>/dev/null)"
    new_img="$(docker image inspect -f '{{.Id}}' "$(get container.image)" 2>/dev/null)"
    if [ "${cur_mode:-}" != "$mode" ]; then
      log "existing container is mode '${cur_mode:-unknown}', requested '$mode' — recreating (Android /data persists)…"
      docker rm -f "$(container_name)" >/dev/null 2>&1 || true
    elif [ -n "$new_img" ] && [ "${cur_img:-}" != "$new_img" ]; then
      log "existing container predates the currently-pulled image — recreating (Android /data persists)…"
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
      # KDE Plasma 6 is WAYLAND: the Waydroid window is a native Wayland toplevel — X11
      # tools (xdotool/xprop/wmctrl) can't see it. kdotool (KWin scripting) CAN, verified
      # live (class=Waydroid). GUI-bound invariant, Wayland-native: show the UI, wait for
      # the window, then block until the user CLOSES it → tear the container down (falls
      # through to cmd_down below). show-full-ui returns immediately (it only fires the
      # intent, confirmed), so it can't be the blocker — the window poll is.
      docker exec -d "$(container_name)" waydroid show-full-ui 2>/dev/null || true
      local kd wc; kd="$(rd_kdotool 2>/dev/null || true)"; wc="$(get display.window_class)"
      if [ -z "$kd" ]; then
        warn "kdotool not found — window-close can't auto-stop; container stays up (stop with: waydroid down)"
        log "Waydroid is a NATIVE window on your desktop — one cursor, native touch/trackpad/audio."
        return 0
      fi
      log "Waydroid is a NATIVE window on your desktop — one cursor, native touch/trackpad/audio."
      local seen=""
      for _ in $(seq 1 30); do
        [ -n "$("$kd" search --class "$wc" 2>/dev/null | head -1)" ] && { seen=1; break; }
        sleep 2
      done
      # Guard: only teardown if we actually SAW the window — otherwise a detection miss
      # would stop a healthy container prematurely.
      [ -n "$seen" ] || { warn "native window not detected via kdotool — leaving container up (stop with: waydroid down)"; return 0; }
      log "  close the window to stop the container (no GUI ⇒ no container)."
      while [ -n "$("$kd" search --class "$wc" 2>/dev/null | head -1)" ]; do sleep 2; done
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
  build)   cmd_build ;;
  bundle)  cmd_bundle ;;
  apps-lock)  shift; cmd_apps_lock "$@" ;;
  apps-fetch) cmd_apps_fetch ;;
  bake)    cmd_bake ;;
  reseal)  cmd_reseal ;;
  install) cmd_install "${2:-}" ;;
  up)      cmd_up "${2:-}" ;;
  down)    cmd_down ;;
  status)  cmd_status ;;
  test)    cmd_test ;;
  push)    cmd_push ;;
  *) die "unknown command '$1'
  build | bundle | apps-lock [pkg...] | apps-fetch | bake | install [bindir] | up [native|stream|vnc] | down | status | test | push" ;;
esac
