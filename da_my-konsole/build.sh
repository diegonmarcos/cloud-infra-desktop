#!/usr/bin/env bash
# my-konsole engine. All heavy steps run inside `nix develop` (flake.nix), so
# the host never needs cargo/webkit/node. Rust/Tauri compile is heavy → CI
# (ship-my-konsole-app.yml) is the normal build path; local `build` is for devs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

log()  { printf '\033[0;36m[my-konsole]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[my-konsole] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

APP_ID="com.diegonmarcos.my-konsole"
BIN="my-konsole"

# Vendor xterm.js browser assets into frontend/vendor (names match index.html).
vendor() {
  log "Vendoring xterm assets…"
  mkdir -p frontend/vendor   # git doesn't track the empty dir; recreate on fresh checkout
  local tmp; tmp="$(mktemp -d)"
  ( cd "$tmp"
    npm init -y >/dev/null 2>&1
    npm install --no-audit --no-fund --silent \
      @xterm/xterm@^5 @xterm/addon-fit@^0.10 @xterm/addon-search@^0.15 >/dev/null 2>&1
  )
  local nm="$tmp/node_modules"
  command cp -f "$nm/@xterm/xterm/lib/xterm.js"                 frontend/vendor/xterm.js
  command cp -f "$nm/@xterm/xterm/css/xterm.css"               frontend/vendor/xterm.css
  command cp -f "$nm/@xterm/addon-fit/lib/addon-fit.js"        frontend/vendor/xterm-addon-fit.js
  command cp -f "$nm/@xterm/addon-search/lib/addon-search.js"  frontend/vendor/xterm-addon-search.js
  rm -rf "$tmp"
  log "Vendored: $(command ls frontend/vendor | tr '\n' ' ')"
}

# Copy data profiles next to the built binary as Tauri resources (bundled).
stage_resources() {
  mkdir -p src-tauri/profiles
  command cp -rf src/data/profiles/* src-tauri/profiles/ 2>/dev/null || true
}

# Sync repo profiles → user dir. get_profiles prefers this over the bundled
# copy, so profile edits apply on the next launch WITHOUT a rebuild.
sync_profiles() {
  local dst="$HOME/.local/share/my-konsole/profiles"
  mkdir -p "$dst"
  command cp -rf src/data/profiles/* "$dst/" 2>/dev/null || true
  log "Synced profiles → $dst"
}

icon() {
  mkdir -p src-tauri/icons
  # Render the personalized icon.svg → PNGs (via imagemagick in the dev shell).
  if [ -f icon.svg ] && nix develop -c magick -background none icon.svg \
        -resize 256x256 src-tauri/icons/icon.png 2>/dev/null; then
    nix develop -c magick -background none icon.svg -resize 128x128 src-tauri/icons/128x128.png 2>/dev/null || true
    nix develop -c magick -background none icon.svg -resize 32x32   src-tauri/icons/32x32.png   2>/dev/null || true
    return 0
  fi
  # Fallback: a valid 1x1 PNG so tauri-build's icon validation still passes.
  [ -f src-tauri/icons/icon.png ] && return 0
  printf '%s' \
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==' \
    | base64 -d > src-tauri/icons/icon.png
}

cmd_build() {
  vendor; stage_resources; icon
  log "cargo tauri build (release)…"
  nix develop -c cargo tauri build
  log "Built. Bundle under src-tauri/target/release/bundle/"
}

cmd_dev()   { vendor; stage_resources; icon; nix develop -c cargo tauri dev; }
# check also stages resources + icon: tauri's build.rs validates the
# tauri.conf.json `resources`/`icon` globs even under `cargo check`.
cmd_check() { stage_resources; icon; nix develop -c cargo check --manifest-path src-tauri/Cargo.toml; }
cmd_clean() { rm -rf src-tauri/target src-tauri/profiles frontend/vendor/*.js frontend/vendor/*.css; }

# Fetch the CI-built binary from the rolling GitHub Release into the store dir.
STORE="$HOME/.local/share/my-konsole"
cmd_fetch() {
  mkdir -p "$STORE"
  command -v gh >/dev/null 2>&1 || die "gh CLI required to fetch the CI binary"
  log "Fetching my-konsole binary from GH release my-konsole-latest…"
  gh release download my-konsole-latest --repo diegonmarcos/unix \
     --pattern "$BIN" --dir "$STORE" --clobber || die "release download failed"
  chmod +x "$STORE/$BIN"
  log "Fetched → $STORE/$BIN"
}

# Launch the binary (local build > fetched) using ONLY runtime libs.
cmd_run() {
  sync_profiles
  local bin="${1:-}"
  if [ -z "$bin" ]; then
    if   [ -x "src-tauri/target/release/$BIN" ]; then bin="src-tauri/target/release/$BIN"
    elif [ -x "$STORE/$BIN" ];                    then bin="$STORE/$BIN"
    else cmd_fetch; bin="$STORE/$BIN"; fi
  fi
  [ -x "$bin" ] || die "no binary at $bin (build or fetch first)"
  # Cache the runtime lib path to disk: `nix eval` realizes the webkit closure
  # (slow first time). Read the cached value on later launches → instant exec.
  local cache="$STORE/runtime-libpath" libpath=""
  [ -s "$cache" ] && libpath="$(command cat "$cache")"
  if [ -z "$libpath" ]; then
    libpath="$(nix eval --raw "$HERE#runtimeLibPath" 2>/dev/null || true)"
    [ -n "$libpath" ] && { mkdir -p "$STORE"; printf '%s' "$libpath" > "$cache"; }
  fi
  # WEBKIT_DISABLE_COMPOSITING_MODE=1: force software compositing so the webview
  # doesn't probe GBM/DRI (harmless GBM errors on the Surface's iGPU otherwise).
  # WEBKIT_DISABLE_DMABUF_RENDERER=1 is the newer WebKitGTK knob for the same.
  LD_LIBRARY_PATH="${libpath}:${LD_LIBRARY_PATH:-}" \
    WEBKIT_DISABLE_COMPOSITING_MODE=1 WEBKIT_DISABLE_DMABUF_RENDERER=1 \
    MYK_SHELL="${MYK_SHELL:-fish}" exec "$bin"
}

# install — write a ~/.local/bin/my-konsole launcher (→ build.sh run). Idempotent.
cmd_install() {
  sync_profiles
  mkdir -p "$HOME/.local/bin"
  local launcher="$HOME/.local/bin/$BIN"
  cat > "$launcher" <<EOF
#!/usr/bin/env bash
# my-konsole launcher (generated by build.sh install) — never edit.
exec "$HERE/build.sh" run
EOF
  chmod +x "$launcher"
  log "Installed launcher → $launcher"
}

case "${1:-build}" in
  build)    cmd_build ;;
  dev)      cmd_dev ;;
  check)    cmd_check ;;
  run)      shift; cmd_run "${1:-}" ;;
  fetch)    cmd_fetch ;;
  install)  cmd_install ;;
  profiles) sync_profiles ;;
  clean)    cmd_clean ;;
  vendor)   vendor ;;
  *)        echo "Usage: $0 [build|dev|check|run|fetch|install|profiles|clean|vendor]" ;;
esac
