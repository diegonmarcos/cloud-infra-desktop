#!/usr/bin/env bash
# redroid-cloud — Redroid delivered as a BAKED GHCR image (Waydroid replacement).
#
# The app set + Launcher3 layout + theme are BAKED INTO THE IMAGE in CI (data-snapshot):
# `bake` boots base redroid once, installs the 58 apps + renders the layout + applies the
# theme, snapshots /data, and docker-builds an image that ships that snapshot + a first-boot
# seed. Runtime is just `up` = docker pull + docker run — the container starts FULLY
# PROVISIONED like Waydroid, with ZERO runtime install ("activation mode" is gone).
# Everything data-driven from build.json (apps, layout, theme, image ref); nothing hardcoded.
#
# RUNTIME (local, on-demand — never auto-started):
#   ./build.sh up        # docker pull + run the baked image (image's seed fills /data once)
#   ./build.sh down      # docker stop
#   ./build.sh scrcpy    # mirror/control the display over ADB
#   ./build.sh status    # container + baked-image + hotseat/workspace
#
# IMAGE BUILD (CI — heavy; runs on a GHA runner, never the 8GB laptop):
#   ./build.sh bake      # boot base + install+layout+theme + snapshot /data + docker build
#   ./build.sh push      # push the baked image to GHCR
#   ./build.sh ship      # bake + push
#
# bake-internal (run against the transient bake container; NOT for runtime):
#   lock | build | check | install | layout | theme | wallpaper | provision | home | undock | clean
#   (default = up)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$ROOT/build.json"
SRC="$ROOT/$(node -e "process.stdout.write(require('$CONFIG').paths.src)")"
DIST="$ROOT/$(node -e "process.stdout.write(require('$CONFIG').paths.dist)")"
APK_DIR="$ROOT/$(node -e "process.stdout.write(require('$CONFIG').paths.apk_dir)")"
LOCKFILE="$ROOT/$(node -e "process.stdout.write(require('$CONFIG').paths.lockfile)")"
BACKUP_DIR="$ROOT/$(node -e "process.stdout.write(require('$CONFIG').paths.backup_dir)")"
WALLPAPER="$ROOT/$(node -e "process.stdout.write(require('$CONFIG').paths.wallpaper)")"

c_g='\033[0;32m'; c_y='\033[0;33m'; c_r='\033[0;31m'; c_0='\033[0m'
log()  { printf "${c_g}[redroid-apps]${c_0} %s\n" "$*"; }
warn() { printf "${c_y}[redroid-apps]${c_0} %s\n" "$*"; }
die()  { printf "${c_r}[redroid-apps] ERROR:${c_0} %s\n" "$*" >&2; exit 1; }

get()      { node -e "const c=require('$CONFIG');const v='$1'.split('.').reduce((o,k)=>o&&o[k],c);process.stdout.write(String(v??''))"; }
get_json() { node -e "const c=require('$CONFIG');const v='$1'.split('.').reduce((o,k)=>o&&o[k],c);process.stdout.write(JSON.stringify(v??null))"; }

# ── reproducible host tools (not on PATH under sudo) ────────────────────────
# Resolve from nixpkgs on demand (same idiom for sqlite/adb/scrcpy) so the engine
# has no host-install dependency and is reproducible.
tool() {  # tool <nixpkgs-attr> <binname>
  local b; b="$(nix build --no-link --print-out-paths "nixpkgs#$1" 2>/dev/null | head -1)/bin/$2"
  [ -x "$b" ] || die "could not resolve $2 via nixpkgs#$1"
  printf '%s' "$b"
}
rd_sqlite3() { tool sqlite-interactive sqlite3; }
rd_adb()     { command -v adb >/dev/null 2>&1 && { command -v adb; return; }; tool android-tools adb; }

ADB=""
# adb endpoint. Connect straight to the container's bridge IP, NOT the published
# 127.0.0.1:<port> — docker's userland-proxy mangles the adb wire protocol, so
# adbd accepts the transport then immediately marks it "offline" (adbd logs
# "host-N: already offline") and the device never leaves the offline state.
# Talking to the container IP directly (proven: 127.0.0.1 → offline, container IP
# → device) sidesteps the proxy entirely. IP is resolved LIVE from the running
# container (reproducible, no hardcoded subnet); the adbd port is the port of the
# configured redroid.adb_addr. Falls back to the static addr before the container
# exists (early connect attempts) so nothing breaks pre-`up`.
adb_port_internal() { get redroid.adb_addr | awk -F: '{ print $NF }'; }
adb_addr() {
  local ip; ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(container_name)" 2>/dev/null)"
  if [ -n "$ip" ]; then printf '%s:%s' "$ip" "$(adb_port_internal)"; else get redroid.adb_addr; fi
}
adb_() { [ -n "$ADB" ] || ADB="$(rd_adb)"; "$ADB" -s "$(adb_addr)" "$@"; }
adb_connect() { [ -n "$ADB" ] || ADB="$(rd_adb)"; "$ADB" connect "$(adb_addr)" >/dev/null 2>&1 || true; }
rd_shell() { adb_ shell "$@"; }

# --cpus for docker run: the configured policy (redroid.cpu_cores) CLAMPED to the CPUs
# actually available on this host — so the SP8 gets 7 but a 4-vCPU CI runner gets 4
# (docker rejects --cpus > nproc). Data-driven cap, no hardcoded per-host value.
cpu_cap() {
  local want avail; want="$(get redroid.cpu_cores)"; avail="$(nproc 2>/dev/null || echo 4)"
  [ "$want" -le "$avail" ] 2>/dev/null && printf '%s' "$want" || printf '%s' "$avail"
}
container_name() { get redroid.container_name; }
container_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$(container_name)"; }
container_exists()  { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$(container_name)"; }
require_up() {
  container_running || die "redroid container '$(container_name)' is not running. Start it: ./build.sh up"
  # Bounded wait for the adb transport to reach 'device' — NEVER a bare
  # `adb wait-for-device`, which blocks forever if the connect never lands
  # (e.g. a stale offline transport) and hangs the whole launch.
  local n; for n in $(seq 1 30); do
    [ "$(adb_ get-state 2>/dev/null)" = "device" ] && return 0
    adb_connect; sleep 1
  done
  warn "adb device not online within 30s ($(adb_addr))"
}

# ── Redroid data volume (host path bind-mounted to container /data) ─────────
rd_data_root() {
  local r; r="$(get redroid.data_volume)"
  [ -n "$r" ] || die "redroid.data_volume not set in build.json"
  printf '%s' "$r"
}
rd_db() {
  local root glob db
  root="$(rd_data_root)"
  glob="$(get redroid.launcher_db_glob)"
  # grid-dependent filename (launcher_<cols>_by_<rows>.db) -> glob, never assume
  db="$(sudo find "$root" -path "$root/$glob" 2>/dev/null | sort | head -1)"
  [ -n "$db" ] || die "launcher DB not found under $root/$glob (has the launcher run once?)"
  printf '%s' "$db"
}

# ── up/down: manage the redroid container (data-driven docker args) ─────────
# Backend only: ensure the container exists, is running, and Android has booted.
# NOT a user-facing launch — cmd_up wraps this and ALWAYS attaches the GUI. There
# is deliberately no command that leaves this running headless.
_ensure_booted() {
  command -v docker >/dev/null 2>&1 || die "docker not found (NixOS: virtualisation.docker.enable)"
  if container_running; then log "container '$(container_name)' already running"; adb_connect; return 0; fi
  local data; data="$(rd_data_root)"; sudo mkdir -p "$data"
  if container_exists; then
    log "starting existing container '$(container_name)'…"
    docker start "$(container_name)" >/dev/null
  else
    # Run the BAKED GHCR image (apps + layout + theme already inside it). Pull if absent.
    # First boot: the image's post-fs-data seed populates the empty /data volume ONCE, so
    # the container comes up FULLY PROVISIONED — no runtime install.
    local img; img="$(get redroid.image)"
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      log "pulling baked image $img …"
      docker pull "$img" || die "docker pull $img failed — is it built? (GHA ship-redroid-image.yml → GHCR). Build locally with: ./build.sh bake"
    fi
    log "creating redroid container '$(container_name)' from baked image $img…"
    # Data-driven DNS: docker's default resolv.conf points at the host stub
    # (127.0.0.53), unreachable from the container's netns, so Android gets no DNS.
    # Pass explicit public resolvers (redroid.dns[]) — Android's init copies these
    # from the container resolv.conf into net.dnsN. Works once docker0 has NAT
    # (networking.nat in docker-daemon-firewall.nix).
    local dns_flags=(); local _d
    while IFS= read -r _d; do [ -n "$_d" ] && dns_flags+=(--dns "$_d"); done \
      < <(node -e "const c=require('./build.json');(c.redroid.dns||[]).forEach(x=>console.log(x))")
    # Data-driven docker run: privileged (binder), persistent /data volume, adb port, cpu cap.
    # selinux permissive lets the baked first-boot seed extract + restorecon /data.
    docker run -d --name "$(container_name)" \
      --privileged \
      --cpus "$(cpu_cap)" \
      -v "$data:/data" \
      -p "$(get redroid.adb_port):5555" \
      "${dns_flags[@]}" \
      "$img" \
      androidboot.redroid_width="$(get redroid.width)" \
      androidboot.redroid_height="$(get redroid.height)" \
      androidboot.redroid_dpi="$(get redroid.dpi)" \
      androidboot.redroid_fps="$(get redroid.fps)" \
      androidboot.redroid_gpu_mode="$(get redroid.gpu_mode)" \
      androidboot.selinux="$(get redroid.selinux)" >/dev/null
  fi
  adb_connect
  log "waiting for Android to boot ($(get redroid.boot_gate_prop))…"
  local i gate; gate="$(get redroid.boot_gate_prop)"
  for ((i=0;i<60;i++)); do
    adb_connect
    [ "$(rd_shell getprop "$gate" 2>/dev/null | tr -d '\r')" = "1" ] && { log "booted."; return 0; }
    sleep 2
  done
  warn "boot gate '$gate' not 1 within 120s — continuing; the GUI may show a black screen until boot finishes"
}

# _run_gui — the ONLY way redroid is ever surfaced. Attaches scrcpy in the
# FOREGROUND and, when the GUI window closes, stops the container. This is what
# makes "no GUI ⇒ no running redroid" true: the detached `docker run` is only the
# Android backend for this window, never a standalone headless runtime.
_run_gui() {
  require_up   # bounded wait until the container-IP adb transport is 'device' —
               # scrcpy fails instantly if it launches before the device is online
  local sc; sc="$(command -v scrcpy 2>/dev/null || tool scrcpy scrcpy)"
  log "launching scrcpy GUI on $(adb_addr)…"
  # --no-audio: redroid has no audio HAL, so the audio encoder throws
  # NAME_NOT_FOUND and spams the log — disable it up front (video-only mirror).
  "$sc" -s "$(adb_addr)" --no-audio --window-title "Redroid" "$@" || true
  log "GUI closed — stopping redroid (no GUI ⇒ no running container)…"
  cmd_down
}

# up = THE runtime launch. Boot the backend, then ALWAYS attach the GUI. Redroid
# must NEVER be launched without the GUI, so up blocks on scrcpy and tears the
# container down on close. `scrcpy` is an alias for the same GUI-bound launch.
cmd_up() { _ensure_booted; _run_gui "$@"; }
cmd_down() {
  container_exists || { log "container '$(container_name)' does not exist"; return 0; }
  log "stopping container '$(container_name)'…"; docker stop "$(container_name)" >/dev/null || true
}

# ── lock: resolve pinned versions + hashes from F-Droid ─────────────────────
cmd_lock() {
  local api repo
  api="$(get fdroid.api_url)"; repo="$(get fdroid.repo_url)"
  # Optional package filter: `build.sh lock [pkg ...]` relocks ONLY those packages,
  # MERGING into the existing lockfile (surgical pin refresh). No args = full regen.
  local -a filter=( "$@" )
  local tmp; tmp="$(mktemp)"
  if [ "${#filter[@]}" -gt 0 ] && [ -f "$LOCKFILE" ]; then
    log "Relocking ${#filter[@]} package(s), merging into existing lockfile: ${filter[*]}"
    cp -f "$LOCKFILE" "$tmp"
  else
    [ "${#filter[@]}" -gt 0 ] && warn "no existing lockfile — falling back to full lock"
    filter=()
    log "Resolving F-Droid versions + hashes (this fetches each APK once to pin its sha256)…"
    echo '{"_doc":"GENERATED by build.sh lock — do not edit by hand. Re-run lock to refresh.","generated_for":"redroid-apps","apps":[]}' > "$tmp"
  fi

  local n; n="$(node -e "process.stdout.write(String(require('$CONFIG').apps.length))")"
  local i pkg stype
  for ((i=0;i<n;i++)); do
    pkg="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].package)")"
    if [ "${#filter[@]}" -gt 0 ]; then
      local _m=0 _fp
      for _fp in "${filter[@]}"; do [ "$_fp" = "$pkg" ] && _m=1; done
      [ "$_m" = 1 ] || continue
    fi
    stype="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].source.type)")"
    case "$stype" in
      fdroid)
        local vc url pref
        vc="$(curl -fsSL "$api/$pkg" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>process.stdout.write(String(JSON.parse(d).suggestedVersionCode)))')"
        [ -n "$vc" ] && [ "$vc" != "undefined" ] || die "could not resolve suggestedVersionCode for $pkg"
        url="$repo/${pkg}_${vc}.apk"
        log "  $pkg -> versionCode $vc ; prefetching…"
        pref="$(nix store prefetch-file --json "$url")"
        local sha
        sha="$(printf '%s' "$pref" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>process.stdout.write(JSON.parse(d).hash))')"
        node -e "
          const fs=require('fs');const f='$tmp';const o=JSON.parse(fs.readFileSync(f));
          o.apps=o.apps.filter(a=>a.package!=='$pkg');
          o.apps.push({package:'$pkg',source:'fdroid',versionCode:$vc,url:'$url',sha256:'$sha'});
          fs.writeFileSync(f,JSON.stringify(o,null,2));"
        ;;
      github)
        local url sha
        url="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].source.url||'')")"
        [ -n "$url" ] || die "github source for $pkg has no url in build.json"
        log "  $pkg -> github ; prefetching…"
        sha="$(nix store prefetch-file --json "$url" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>process.stdout.write(JSON.parse(d).hash))')"
        node -e "
          const fs=require('fs');const f='$tmp';const o=JSON.parse(fs.readFileSync(f));
          o.apps=o.apps.filter(a=>a.package!=='$pkg');
          o.apps.push({package:'$pkg',source:'github',url:'$url',sha256:'$sha'});
          fs.writeFileSync(f,JSON.stringify(o,null,2));"
        ;;
      local)
        log "  $pkg -> local build (not locked; built by build.sh build)"
        ;;
      *) die "unknown source.type '$stype' for $pkg" ;;
    esac
  done
  mkdir -p "$(dirname "$LOCKFILE")"
  mv "$tmp" "$LOCKFILE"
  log "Lockfile written: $LOCKFILE"
}

# Try the GHA-prebuilt APK set (rolling GitHub Release) instead of fetching ~54
# APKs from F-Droid locally. Data-driven (build.json release{}). Reproducible: the
# tarball bundles manifest.json (a verbatim copy of the lockfile it was built from) —
# we only accept it if that equals our local lockfile. Returns 0 if it populated
# $APK_DIR, 1 to fall back. Force local build with REDROID_APKS_LOCAL=1.
try_apks_from_release() {
  [ "${REDROID_APKS_LOCAL:-0}" = "1" ] && return 1
  [ "$(get release.consume)" = "true" ] || return 1
  local tag asset; tag="$(get release.tag)"; asset="$(get release.asset)"
  [ -n "$tag" ] && [ -n "$asset" ] || return 1
  command -v gh >/dev/null 2>&1 || { warn "release.consume set but gh not found — building locally"; return 1; }
  local t; t="$(mktemp -d)"
  log "fetching prebuilt APK set from release '$tag'…"
  if ! gh release download "$tag" -p "$asset" -D "$t" >/dev/null 2>&1; then
    warn "release '$tag' asset '$asset' unavailable — building locally"; rm -rf "$t"; return 1
  fi
  tar -C "$t" -xzf "$t/$asset" 2>/dev/null || { warn "cannot extract '$asset' — building locally"; rm -rf "$t"; return 1; }
  if ! node -e "const fs=require('fs');const A=JSON.stringify(JSON.parse(fs.readFileSync('$t/manifest.json')).apps);const B=JSON.stringify(JSON.parse(fs.readFileSync('$LOCKFILE')).apps);process.exit(A===B?0:1)" 2>/dev/null; then
    warn "release manifest != local lockfile (stale) — building locally"; rm -rf "$t"; return 1
  fi
  cp -f "$t/apks/"*.apk "$APK_DIR"/ 2>/dev/null || { rm -rf "$t"; return 1; }
  log "Pulled $(ls "$APK_DIR" | wc -l) prebuilt APK(s) from release '$tag' (no local nix build)"
  rm -rf "$t"; return 0
}

# ── build: fetch pinned APKs (prebuilt release, else nix) + copy local APKs ──
cmd_build() {
  [ -f "$LOCKFILE" ] || { warn "no lockfile; running lock first"; cmd_lock; }
  rm -rf "$APK_DIR"; mkdir -p "$APK_DIR"
  mkdir -p "$DIST"
  if ! try_apks_from_release; then
    log "nix build of pinned APK set…"
    nix build "path:$SRC#apks" --no-link --print-out-paths > "$DIST/.apks.out"
    local out; out="$(cat "$DIST/.apks.out")"
    cp -f "$out"/apks/*.apk "$APK_DIR"/
    log "Fetched $(ls "$APK_DIR" | wc -l) pinned APK(s) into dist/apks/"
  fi

  # local-source apps (e.g. cloud-superapp x86_64)
  local n; n="$(node -e "process.stdout.write(String(require('$CONFIG').apps.length))")"
  local i
  for ((i=0;i<n;i++)); do
    local stype pkg
    stype="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].source.type)")"
    [ "$stype" = "local" ] || continue
    pkg="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].package)")"
    local proj glob varenv varval found
    proj="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].source.build_project)")"
    glob="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].source.apk_glob)")"
    varenv="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].source.build_variant_env||'')")"
    varval="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].source.build_variant||'')")"
    found="$(ls "$ROOT/$proj"/$glob 2>/dev/null | head -1 || true)"
    if [ -z "$found" ]; then
      warn "local app $pkg: no prebuilt APK at $proj/$glob."
      warn "  Build it with: ( cd $proj && ${varenv:+$varenv=$varval }./build.sh build )  then re-run."
      continue
    fi
    cp -f "$found" "$APK_DIR/$pkg.apk"
    log "  local $pkg -> $(basename "$found")"
  done
}

cmd_nix() { nix build "path:$SRC#apks" --print-out-paths; }

# ── check: lockfile <-> build.json + APK presence ───────────────────────────
cmd_check() {
  [ -f "$LOCKFILE" ] || die "no lockfile — run: ./build.sh lock"
  node -e "
    const cfg=require('$CONFIG'), lock=require('$LOCKFILE');
    const want=cfg.apps.filter(a=>a.source.type==='fdroid'||a.source.type==='github').map(a=>a.package).sort();
    const have=lock.apps.map(a=>a.package).sort();
    const miss=want.filter(p=>!have.includes(p)), extra=have.filter(p=>!want.includes(p));
    if(miss.length||extra.length){console.error('lockfile drift. missing:',miss,'stale:',extra);process.exit(1);}
    console.log('lockfile matches build.json ('+want.length+' remote apps)');
  " || die "lockfile out of sync with build.json — run: ./build.sh lock"
  local n missing=0; n="$(node -e "process.stdout.write(String(require('$CONFIG').apps.length))")"
  local i pkg
  for ((i=0;i<n;i++)); do
    pkg="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].package)")"
    if [ -f "$APK_DIR/$pkg.apk" ]; then printf '  ✓ %s\n' "$pkg"; else printf "  ${c_r}✗ %s (missing APK)${c_0}\n" "$pkg"; missing=1; fi
  done
  [ "$missing" -eq 0 ] || die "some APKs missing — run: ./build.sh build"
  log "check OK"
}

# ── install: adb install every built APK ────────────────────────────────────
cmd_install() {
  require_up
  # -g auto-grants all declared runtime permissions at install (no prompts); -r replace, -d downgrade ok.
  local grantflag=""; [ "$(get redroid.grant_all_permissions)" = "true" ] && grantflag="-g"
  local n; n="$(node -e "process.stdout.write(String(require('$CONFIG').apps.length))")"
  local i pkg
  for ((i=0;i<n;i++)); do
    pkg="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].package)")"
    [ -f "$APK_DIR/$pkg.apk" ] || { warn "skip $pkg (no APK; run build)"; continue; }
    log "installing $pkg…"
    local out; out="$(adb_ install -r -d $grantflag "$APK_DIR/$pkg.apk" 2>&1)"; out="${out//$'\r'/}"
    if [[ "$out" != *Success* ]]; then
      # Signing-key change → adb refuses -r replace across signatures; uninstall + reinstall (loses data).
      if [[ "$out" == *"signatures do not match"* || "$out" == *INSTALL_FAILED_UPDATE_INCOMPATIBLE* || "$out" == *INCONSISTENT_CERTIFICATES* || "$out" == *"signature"* ]]; then
        warn "  $pkg signing key changed → uninstall + reinstall"
        adb_ uninstall "$pkg" >/dev/null 2>&1 || true
        out="$(adb_ install -d $grantflag "$APK_DIR/$pkg.apk" 2>&1)"; out="${out//$'\r'/}"
      fi
      [[ "$out" == *Success* ]] || warn "  install issue for $pkg: ${out##*$'\n'}"
    fi
    if rd_shell pm path "$pkg" >/dev/null 2>&1; then log "  ✓ $pkg present"; else warn "  ✗ $pkg NOT present after install"; fi
    # Data-driven special app-ops (separate from -g runtime perms), e.g. REQUEST_INSTALL_PACKAGES.
    local nops; nops="$(node -e "process.stdout.write(String((require('$CONFIG').apps[$i].appops||[]).length))")"
    local j op
    for ((j=0;j<nops;j++)); do
      op="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].appops[$j])")"
      if rd_shell appops set "$pkg" "$op" allow >/dev/null 2>&1; then log "  appop $op = allow"; else warn "  appop $op failed for $pkg"; fi
    done
  done
  log "install pass complete"
}

# ── layout: render the data-driven launcher layout (folders+hotseat+workspace) ──
resolve_component() {
  local pkg="$1" out
  out="$(rd_shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$pkg" 2>/dev/null || true)"
  out="${out//$'\r'/}"
  printf '%s' "$out" | awk 'NF{l=$0} END{print l}'   # last non-empty line = "<pkg>/<activity>"
}

cmd_layout() {
  require_up
  local db; db="$(rd_db)"
  local SQ; SQ="$(rd_sqlite3)"
  log "launcher DB: $db"

  # unique package set referenced anywhere in launcher{} (folders + hotseat + workspace)
  local pkgs; pkgs="$(node -e "
    const l=require('$CONFIG').launcher; const s=new Set();
    Object.entries(l.folders).forEach(([k,f])=>{ if(k.startsWith('_')||!f||!Array.isArray(f.members)) return; f.members.forEach(m=>s.add(m)); });
    l.hotseat.forEach(r=>{ if(!String(r).startsWith('folder:')) s.add(r); });
    l.workspace.cells.forEach(c=>{ if(!String(c.ref).startsWith('folder:')) s.add(c.ref); });
    console.log([...s].join('\n'));
  ")"

  # resolve each package's launcher component live -> COMPONENTS_J map
  local compfile="$DIST/.components.tsv"; mkdir -p "$DIST"; : > "$compfile"
  local pkg comp
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    comp="$(resolve_component "$pkg")"
    if [ -z "$comp" ] || [[ "$comp" != *"/"* ]]; then warn "unresolved (installed?): $pkg"; continue; fi
    printf '%s\t%s\n' "$pkg" "$comp" >> "$compfile"
  done <<< "$pkgs"
  local COMPONENTS_J; COMPONENTS_J="$(node -e "
    const fs=require('fs');const m={};
    for(const l of fs.readFileSync('$compfile','utf8').split('\n')){ if(!l.trim())continue; const [p,c]=l.split('\t'); m[p]=c; }
    process.stdout.write(JSON.stringify(m));
  ")"

  # backup
  mkdir -p "$BACKUP_DIR"
  local ts bak; ts="$(node -e "process.stdout.write(String(Date.now()))")"
  bak="$BACKUP_DIR/launcher.db.$ts.bak"
  sudo cp -f "$db" "$bak"; sudo chown "$USER" "$bak" 2>/dev/null || true
  log "backed up launcher.db -> $bak"

  # generate the full layout SQL from build.json launcher{}
  local sqlfile="$DIST/layout.sql"
  FOLDERS_J="$(node -e "process.stdout.write(JSON.stringify(require('$CONFIG').launcher.folders))")" \
  HOTSEAT_J="$(node -e "process.stdout.write(JSON.stringify(require('$CONFIG').launcher.hotseat))")" \
  WORKSPACE_J="$(node -e "process.stdout.write(JSON.stringify(require('$CONFIG').launcher.workspace))")" \
  COMPONENTS_J="$COMPONENTS_J" \
  HOTSEAT_CONTAINER="$(get redroid.hotseat_container)" \
  WORKSPACE_CONTAINER="$(get redroid.workspace_container)" \
  FLAGS="$(get redroid.launch_flags)" \
  ITEM_APP="$(get redroid.item_type_application)" \
  ITEM_FOLDER="$(get redroid.item_type_folder)" \
  node "$SRC/lib/gen-layout-sql.js" > "$sqlfile"
  log "generated $sqlfile ($(grep -c '^INSERT' "$sqlfile") rows)"

  # apply with launcher stopped, then relaunch. CRITICAL: sqlite3 runs as root on the
  # host volume, so the db + -wal/-shm sidecars become root-owned; Launcher3 (its own
  # uid) then can't open them and crash-loops. Capture the db's Android owner BEFORE
  # writing, restore AFTER, and drop the stale WAL/SHM so Launcher3 recreates them.
  local dbowner; dbowner="$(sudo stat -c '%u:%g' "$db")"
  log "stopping launcher, applying layout (restoring db owner $dbowner), relaunching…"
  rd_shell am force-stop "$(get redroid.launcher_package)" 2>/dev/null || true
  sudo "$SQ" "$db" < "$sqlfile" || { warn "sqlite apply failed — restoring backup"; sudo cp -f "$bak" "$db"; sudo chown "$dbowner" "$db"; die "layout aborted, backup restored"; }
  sudo "$SQ" "$db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
  sudo rm -f "$db-wal" "$db-shm"
  sudo chown "$dbowner" "$db"
  rd_shell monkey -p "$(get redroid.launcher_package)" 1 >/dev/null 2>&1 || true

  log "hotseat:"
  sudo "$SQ" -column "$db" "SELECT screen,title,itemType FROM favorites WHERE container=$(get redroid.hotseat_container) ORDER BY screen;" | sed 's/^/    /'
  log "home screen (workspace):"
  sudo "$SQ" -column "$db" "SELECT cellY,cellX,title,itemType FROM favorites WHERE container=$(get redroid.workspace_container) ORDER BY cellY,cellX;" | sed 's/^/    /'
  log "layout applied. (Backup: $bak — restore with: ./build.sh undock)"
}

# ── theme: dark mode + solid-black wallpaper (data-driven) ──────────────────
cmd_wallpaper() {
  local size from to; size="$(get theme.wallpaper.size)"; from="$(get theme.wallpaper.gradient_from)"; to="$(get theme.wallpaper.gradient_to)"
  mkdir -p "$(dirname "$WALLPAPER")"
  log "generating dark wallpaper ($size, $from→$to) via imagemagick…"
  nix shell nixpkgs#imagemagick -c magick -size "$size" "gradient:$from-$to" "$WALLPAPER" \
    || die "wallpaper generation failed (imagemagick)"
  log "wrote $WALLPAPER"
}

cmd_theme() {
  require_up
  if [ "$(get theme.dark_mode)" = "true" ]; then
    log "enabling dark mode (night UI)…"
    rd_shell cmd uimode night yes >/dev/null 2>&1 || true
    rd_shell settings put secure ui_night_mode 2 >/dev/null 2>&1 || true
  fi
  if [ "$(get theme.auto_rotate)" = "true" ]; then
    log "enabling auto-rotate (accelerometer_rotation=1)…"
    rd_shell settings put system accelerometer_rotation 1 >/dev/null 2>&1 || true
  fi
  # wallpaper dim (1.0 = solid black) — AOSP `cmd wallpaper` has no set-image subcommand.
  local dim; dim="$(get theme.wallpaper.dim)"
  if [ -n "$dim" ]; then
    log "setting wallpaper dim to $dim (1.0 = solid black)…"
    rd_shell cmd wallpaper set-dim-amount "$dim" >/dev/null 2>&1 || warn "cmd wallpaper set-dim-amount failed"
  fi
}

# ── provision: the idempotent post-boot steps (install + layout + theme) ────
cmd_provision() { require_up; cmd_install; cmd_layout; cmd_theme; }

# ── scrcpy: alias for the GUI-bound launch (boot backend + attach GUI + teardown
# on close). Same invariant as `up` — redroid is never surfaced without the GUI.
cmd_scrcpy() { _ensure_booted; _run_gui "$@"; }

# ── home: flip the HOME launcher to the SuperApp (Phase 2) ──────────────────
cmd_home() {
  require_up
  local home; home="$(get redroid.home_package)"
  log "setting HOME launcher to $home…"
  rd_shell cmd package set-home-activity "$home" >/dev/null 2>&1 \
    || warn "set-home-activity failed (is $home installed with a HOME activity?)"
}

cmd_undock() {
  require_up
  local db bak; db="$(rd_db)"
  local SQ; SQ="$(rd_sqlite3)"
  bak="$(ls -t "$BACKUP_DIR"/launcher.db.*.bak 2>/dev/null | head -1 || true)"
  [ -n "$bak" ] || die "no backup found in $BACKUP_DIR"
  rd_shell am force-stop "$(get redroid.launcher_package)" 2>/dev/null || true
  sudo cp -f "$bak" "$db"
  sudo "$SQ" "$db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
  log "restored $db from $bak"
}

cmd_status() {
  printf "Container: "; container_running && echo "RUNNING ($(container_name))" || { container_exists && echo "stopped" || echo "not created"; }
  echo "--- declared apps (build.json) ---"
  node -e "require('$CONFIG').apps.forEach(a=>console.log('  ['+a.group+']  '+a.package+'  ('+a.label+')'))"
  echo "--- built APKs (dist/apks) ---"; ls "$APK_DIR" 2>/dev/null | sed 's/^/  /' || echo "  (none — run build)"
  if container_running; then
    adb_connect
    local db; db="$(rd_db 2>/dev/null || true)"
    if [ -n "$db" ]; then
      local SQ; SQ="$(rd_sqlite3)"
      echo "--- live hotseat ---"
      sudo "$SQ" -column "$db" "SELECT screen,title,itemType FROM favorites WHERE container=$(get redroid.hotseat_container) ORDER BY screen;" 2>/dev/null | sed 's/^/  /'
      echo "--- live workspace ---"
      sudo "$SQ" -column "$db" "SELECT cellY,cellX,title,itemType FROM favorites WHERE container=$(get redroid.workspace_container) ORDER BY cellY,cellX;" 2>/dev/null | sed 's/^/  /'
    fi
  fi
}

# ── bake: build the BAKED GHCR image (data-snapshot) — CI-side, heavy ────────
# Boots BASE redroid on a fresh /data, installs the app set + renders the layout +
# theme (the internal install/layout/theme steps — these run ONCE, in CI, never at
# runtime), snapshots /data, and docker-builds src/Dockerfile shipping that snapshot +
# the first-boot seed. Result: a self-contained image that starts fully provisioned.
cmd_bake() {
  command -v docker >/dev/null 2>&1 || die "docker not found"
  [ -f "$LOCKFILE" ] || cmd_lock
  # SYSTEM-APP BAKE — no Android boot (GitHub-hosted runners have no binder, so redroid
  # cannot boot in CI). Apps go into /system/app; the Launcher3 layout is pre-rendered to
  # SQL here (component activities extracted statically via aapt) and applied on first boot
  # by the baked seed. Fully baked, works on any runner.
  local base img ctx sysd rc
  base="$(get image.base)"; img="$(get image.name):$(get image.tag)"; ctx="$DIST/context"; sysd="$ctx/system"
  log "BAKE $img  (system-app bake from base $base — no Android boot)"
  rm -rf "$ctx"; mkdir -p "$sysd/app" "$sysd/etc/redroid-cloud" "$sysd/etc/init"

  # 1) fetch the pinned APK set (reproducible; nix / prebuilt release)
  cmd_build

  # 2) place each APK as a system app + extract its launcher activity statically.
  # nixpkgs#aapt ships aapt2 (not legacy aapt); `aapt2 dump badging` emits the same
  # `launchable-activity: name='…'` line, so component extraction is identical.
  local aapt; aapt="$(nix build --no-link --print-out-paths nixpkgs#aapt 2>/dev/null | head -1)/bin/aapt2"
  [ -x "$aapt" ] || die "aapt2 not found via nixpkgs#aapt"
  local unzip; unzip="$(nix build --no-link --print-out-paths nixpkgs#unzip 2>/dev/null | head -1)/bin/unzip"
  [ -x "$unzip" ] || die "unzip not found via nixpkgs#unzip"
  local abi; abi="$(get redroid.abi)"; [ -n "$abi" ] || abi="x86_64"
  local compfile="$DIST/.components.tsv"; : > "$compfile"
  local n i pkg apk act baked=0 libapps=0
  n="$(node -e "process.stdout.write(String(require('$CONFIG').apps.length))")"
  for ((i=0;i<n;i++)); do
    pkg="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].package)")"
    apk="$APK_DIR/$pkg.apk"; [ -f "$apk" ] || { warn "no APK for $pkg — skipping"; continue; }
    mkdir -p "$sysd/app/$pkg"; cp -f "$apk" "$sysd/app/$pkg/$pkg.apk"; baked=$((baked+1))
    # Extract bundled native libs → /system/app/<pkg>/lib/<abi>/. System apps do NOT get
    # PackageManager's native-lib extraction, so a bare APK with extractNativeLibs=true leaves
    # its .so files compressed-inside-APK and unreachable → dlopen fails → the app crashes on
    # launch (e.g. Brave: libchrome.so / libdatastore_shared_counter.so). Flatten (-j) into lib/<abi>.
    if "$unzip" -l "$apk" 2>/dev/null | grep -q "lib/$abi/.*\.so"; then
      mkdir -p "$sysd/app/$pkg/lib/$abi"
      "$unzip" -o -j "$apk" "lib/$abi/*.so" -d "$sysd/app/$pkg/lib/$abi" >/dev/null 2>&1 && libapps=$((libapps+1))
    fi
    act="$("$aapt" dump badging "$apk" 2>/dev/null | sed -n "s/^launchable-activity: name='\([^']*\)'.*/\1/p" | head -1)"
    [ -n "$act" ] && printf '%s\t%s/%s\n' "$pkg" "$pkg" "$act" >> "$compfile"
  done
  log "system apps: $baked/$n baked into /system/app ($libapps with extracted native libs); components resolved: $(wc -l < "$compfile")"

  # 3) render the Launcher3 favorites SQL from build.json + the static component map
  local COMPONENTS_J; COMPONENTS_J="$(node -e "
    const fs=require('fs');const m={};
    for(const l of fs.readFileSync('$compfile','utf8').split('\n')){ if(!l.trim())continue; const [p,c]=l.split('\t'); m[p]=c; }
    process.stdout.write(JSON.stringify(m));
  ")"
  FOLDERS_J="$(node -e "process.stdout.write(JSON.stringify(require('$CONFIG').launcher.folders))")" \
  HOTSEAT_J="$(node -e "process.stdout.write(JSON.stringify(require('$CONFIG').launcher.hotseat))")" \
  WORKSPACE_J="$(node -e "process.stdout.write(JSON.stringify(require('$CONFIG').launcher.workspace))")" \
  COMPONENTS_J="$COMPONENTS_J" \
  HOTSEAT_CONTAINER="$(get redroid.hotseat_container)" WORKSPACE_CONTAINER="$(get redroid.workspace_container)" \
  FLAGS="$(get redroid.launch_flags)" ITEM_APP="$(get redroid.item_type_application)" ITEM_FOLDER="$(get redroid.item_type_folder)" \
  node "$SRC/lib/gen-layout-sql.js" > "$sysd/etc/redroid-cloud/layout.sql"
  log "layout.sql: $(grep -c '^INSERT' "$sysd/etc/redroid-cloud/layout.sql") rows"

  # 4) baked seed env flags (theme + home-experience) + apps.list + seed + init service.
  #    theme.sh is sourced by the first-boot seed; every knob is data-driven from build.json.
  {
    printf 'DARK=%s\n'          "$([ "$(get theme.dark_mode)"  = true ] && echo 1 || echo 0)"
    printf 'AUTOROTATE=%s\n'    "$([ "$(get theme.auto_rotate)" = true ] && echo 1 || echo 0)"
    printf 'WALLPAPER_DIM=%s\n' "$(get theme.wallpaper.dim)"
    printf 'REMOVE_QSB=%s\n'    "$([ "$(get redroid.remove_qsb)"           = true ] && echo 1 || echo 0)"
    printf 'LOCATION=%s\n'      "$([ "$(get redroid.location_enabled)"      = true ] && echo 1 || echo 0)"
    printf 'GRANT_ALL=%s\n'     "$([ "$(get redroid.grant_all_permissions)" = true ] && echo 1 || echo 0)"
  } > "$sysd/etc/redroid-cloud/theme.sh"
  # apps.list — the baked package ids, one per line. The seed loops it to grant every
  # requested dangerous permission per app (system apps in /system/app are NOT adb-installed,
  # so `adb install -g` never runs for them — the seed is where "all permissions" happens).
  node -e 'const a=require("'"$CONFIG"'").apps||[]; a.forEach(x=>{const p=(typeof x==="string")?x:(x.package||x.pkg||x.id); if(p)console.log(p)})' \
    > "$sysd/etc/redroid-cloud/apps.list"
  log "apps.list: $(wc -l < "$sysd/etc/redroid-cloud/apps.list") packages"
  cp -f "$SRC/seed/redroid-cloud-seed.sh" "$sysd/etc/redroid-cloud/seed.sh"
  cp -f "$SRC/seed/redroid-cloud-seed.rc" "$sysd/etc/init/redroid-cloud-seed.rc"
  cp -f "$SRC/Dockerfile" "$ctx/Dockerfile"

  # 5) build the image (no boot)
  log "docker build $img …"
  docker build --build-arg BASE="$base" -t "$img" "$ctx" || die "docker build failed"
  log "baked: $img"
}
cmd_push() { local img; img="$(get image.name):$(get image.tag)"; log "pushing $img…"; docker push "$img" || die "push failed"; log "pushed $img"; }

# verify: STATIC tester (no boot — works on any runner). Exports the built image's
# filesystem and asserts every declared app is baked at /system/app/<pkg>/<pkg>.apk, plus
# the baked layout.sql + first-boot init service are present. Proves the image ships fully
# baked; the runtime behaviour (apps install at boot, seed applies layout) is exercised
# on a binder host via `./build.sh up` (e.g. the SP8), which CI can't do (no binder).
cmd_verify() {
  local img; img="$(get image.name):$(get image.tag)"
  log "VERIFY (static): $img ships every app + layout + seed…"
  docker image inspect "$img" >/dev/null 2>&1 || die "image $img not built — run: ./build.sh bake"
  local tmp cid; tmp="$(mktemp -d)"
  cid="$(docker create "$img")" || die "cannot create container from $img"
  docker export "$cid" | tar -tf - 2>/dev/null > "$tmp/files.txt"
  docker rm "$cid" >/dev/null 2>&1
  local n i pkg miss=0 present=0 libok=0
  local abi; abi="$(get redroid.abi)"; [ -n "$abi" ] || abi="x86_64"
  local unzip; unzip="$(nix build --no-link --print-out-paths nixpkgs#unzip 2>/dev/null | head -1)/bin/unzip"
  n="$(node -e "process.stdout.write(String(require('$CONFIG').apps.length))")"
  for ((i=0;i<n;i++)); do
    pkg="$(node -e "process.stdout.write(require('$CONFIG').apps[$i].package)")"
    if grep -q "system/app/$pkg/$pkg.apk" "$tmp/files.txt"; then present=$((present+1)); else warn "  MISSING baked app: $pkg"; miss=$((miss+1)); fi
    # If the APK bundles native libs, the image MUST carry them extracted at lib/<abi>/,
    # else the app crashes on dlopen (the Brave libdatastore_shared_counter.so / libchrome.so bug).
    if [ -x "$unzip" ] && [ -f "$APK_DIR/$pkg.apk" ] && "$unzip" -l "$APK_DIR/$pkg.apk" 2>/dev/null | grep -q "lib/$abi/.*\.so"; then
      if grep -q "system/app/$pkg/lib/$abi/" "$tmp/files.txt"; then libok=$((libok+1)); else warn "  MISSING extracted native libs: $pkg (lib/$abi)"; miss=$((miss+1)); fi
    fi
  done
  log "baked system apps: $present/$n ($libok with native libs extracted)"
  grep -q "system/etc/redroid-cloud/layout.sql" "$tmp/files.txt" || { warn "  MISSING baked layout.sql"; miss=$((miss+1)); }
  grep -q "system/etc/init/redroid-cloud-seed.rc" "$tmp/files.txt" || { warn "  MISSING first-boot seed service"; miss=$((miss+1)); }
  rm -rf "$tmp"
  [ "$miss" -eq 0 ] && { log "VERIFY OK — apps + layout + seed baked into the image."; return 0; } || die "VERIFY FAILED — $miss issue(s)"
}

# ship = bake + verify + push (CI). Local runtime is just `up` (pull + run the baked image).
cmd_ship() { cmd_bake; cmd_verify; cmd_push; }
cmd_clean() { sudo rm -rf "$DIST" 2>/dev/null || rm -rf "$DIST"; log "cleaned dist/"; }

case "${1:-up}" in
  # runtime (local): pull + run the baked image — no install, ever.
  up) cmd_up ;;
  down) cmd_down ;;
  scrcpy) shift; cmd_scrcpy "$@" ;;
  status) cmd_status ;;
  # image build (CI): produce + verify + push the baked GHCR image.
  bake) cmd_bake ;;
  verify) cmd_verify ;;
  push) cmd_push ;;
  ship) cmd_ship ;;
  # bake-internal steps (run against a booted container during bake; not for runtime).
  lock) shift; cmd_lock "$@" ;;
  build) cmd_build ;;
  nix) cmd_nix ;;
  check) cmd_check ;;
  install) cmd_install ;;
  layout) cmd_layout ;;
  theme) cmd_theme ;;
  wallpaper) cmd_wallpaper ;;
  provision) cmd_provision ;;
  home) cmd_home ;;
  undock) cmd_undock ;;
  clean) cmd_clean ;;
  *) die "unknown command '$1'
  runtime: up | down | scrcpy | status
  image:   bake | push | ship        (CI: build+push the baked GHCR image)
  bake-internal: lock|build|check|install|layout|theme|wallpaper|provision|home|undock|clean" ;;
esac
