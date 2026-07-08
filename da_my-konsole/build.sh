#!/usr/bin/env bash
# my-konsole engine. 100% DATA-DRIVEN: all identity/config comes from build.json;
# no values are hardcoded here. Heavy steps run inside `nix develop` (flake.nix),
# so the host never needs cargo/webkit/node. Rust/Tauri compile is heavy → CI
# (ship-my-konsole-app.yml) is the normal build path; local `build` is for devs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

log()  { printf '\033[0;36m[my-konsole]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[my-konsole] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq required (reads build.json — the single source of truth)"
cfg() { jq -r "$1" build.json; }

# ── All engine data sourced from build.json (never hardcoded) ──────────────
BIN="$(cfg '.app.bin')"
SHELL_CMD="$(cfg '.app.shell')"
RELEASE_TAG="$(cfg '.build.release_tag')"
REPO="$(cfg '.build.repo')"
STORE="$HOME/$(cfg '.runtime.store_subdir')"

# Vendor xterm.js browser assets → frontend/vendor. Packages + dest names are
# data (.build.vendor / .build.vendor_map), so adding an addon is a JSON edit.
vendor() {
  log "Vendoring xterm assets…"
  mkdir -p frontend/vendor   # git doesn't track the empty dir; recreate on fresh checkout
  local tmp; tmp="$(mktemp -d)"
  local pkgs; mapfile -t pkgs < <(jq -r '.build.vendor | to_entries[] | "\(.key)@\(.value)"' build.json)
  ( cd "$tmp"; npm init -y >/dev/null 2>&1; npm install --no-audit --no-fund --silent "${pkgs[@]}" >/dev/null 2>&1 )
  local src dst
  while IFS=$'\t' read -r src dst; do
    command cp -f "$tmp/node_modules/$src" "frontend/vendor/$dst"
  done < <(jq -r '.build.vendor_map | to_entries[] | "\(.key)\t\(.value)"' build.json)
  rm -rf "$tmp"
  log "Vendored: $(command ls frontend/vendor | tr '\n' ' ')"
}

# Copy data profiles next to the built binary as Tauri resources (bundled).
stage_resources() {
  mkdir -p src-tauri/profiles
  command cp -rf src/data/profiles/* src-tauri/profiles/ 2>/dev/null || true
  # config.json (theme/font/keybindings) ships too — read at runtime.
  command cp -f src/data/config.json src-tauri/config.json 2>/dev/null || true
}

# Sync repo data (profiles + config) → user dir. The app prefers this over the
# bundled copy, so edits apply on the next launch WITHOUT a rebuild.
sync_data() {
  mkdir -p "$STORE/profiles"
  command cp -rf src/data/profiles/* "$STORE/profiles/" 2>/dev/null || true
  command cp -f src/data/config.json "$STORE/config.json" 2>/dev/null || true
  log "Synced profiles + config → $STORE"
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
cmd_clean() { rm -rf src-tauri/target src-tauri/profiles src-tauri/config.json frontend/vendor/*.js frontend/vendor/*.css; }

# Fetch the CI-built binary from the rolling GitHub Release into the store dir.
cmd_fetch() {
  mkdir -p "$STORE"
  command -v gh >/dev/null 2>&1 || die "gh CLI required to fetch the CI binary"
  log "Fetching $BIN from GH release $RELEASE_TAG ($REPO)…"
  gh release download "$RELEASE_TAG" --repo "$REPO" --pattern "$BIN" --dir "$STORE" --clobber \
    || die "release download failed"
  chmod +x "$STORE/$BIN"
  log "Fetched → $STORE/$BIN"
}

# Resolve + cache the webkit runtime lib path. `nix eval` realizes the closure
# (slow first time); the cached value makes later reads instant.
resolve_libpath() {
  local cache="$STORE/runtime-libpath" libpath=""
  [ -s "$cache" ] && libpath="$(command cat "$cache")"
  if [ -z "$libpath" ]; then
    # runtimeLibPath is per-system (flake-utils eachDefaultSystem) → needs the
    # system suffix; `.#runtimeLibPath` alone is a set and won't coerce.
    local sys="$(uname -m)-linux"
    libpath="$(nix eval --raw "$HERE#runtimeLibPath.$sys" 2>/dev/null || true)"
    [ -n "$libpath" ] && { mkdir -p "$STORE"; printf '%s' "$libpath" > "$cache"; }
  fi
  printf '%s' "$libpath"
}

# Launch the binary (local build > fetched) using ONLY runtime libs.
cmd_run() {
  sync_data
  local bin="${1:-}"
  if [ -z "$bin" ]; then
    if   [ -x "src-tauri/target/release/$BIN" ]; then bin="src-tauri/target/release/$BIN"
    elif [ -x "$STORE/$BIN" ];                    then bin="$STORE/$BIN"
    else cmd_fetch; bin="$STORE/$BIN"; fi
  fi
  [ -x "$bin" ] || die "no binary at $bin (build or fetch first)"
  # Runtime env is data-driven (.runtime.env in build.json) — e.g. the WEBKIT
  # software-compositing flags that avoid GBM errors on the Surface iGPU.
  local k v
  while IFS=$'\t' read -r k v; do export "$k=$v"; done \
    < <(jq -r '.runtime.env | to_entries[] | "\(.key)\t\(.value)"' build.json)
  LD_LIBRARY_PATH="$(resolve_libpath):${LD_LIBRARY_PATH:-}" MYK_SHELL="${MYK_SHELL:-$SHELL_CMD}" exec "$bin"
}

# install — self-contained desktop integration (launcher + .desktop + icon),
# all fields from build.json. No home-manager activation needed. Idempotent.
cmd_install() {
  sync_data
  local apps="$HOME/.local/share/applications"
  local icons="$HOME/.local/share/icons/hicolor/scalable/apps"
  mkdir -p "$HOME/.local/bin" "$apps" "$icons"

  # 1. Deploy the binary + a SELF-CONTAINED launcher on PATH (no repo/build.sh
  #    dependency at runtime — webkit libs + env baked in, like a wrapped app).
  local binpath="$STORE/$BIN"
  if [ ! -x "$binpath" ]; then
    if [ -x "src-tauri/target/release/$BIN" ]; then command cp -f "src-tauri/target/release/$BIN" "$binpath"; chmod +x "$binpath";
    else cmd_fetch; fi
  fi
  local libpath; libpath="$(resolve_libpath)"
  local envlines; envlines="$(jq -r '.runtime.env | to_entries[] | "export \(.key)=\(.value)"' build.json)"
  local launcher="$HOME/.local/bin/$BIN"
  {
    echo '#!/usr/bin/env bash'
    echo "# $BIN (generated by build.sh install) — self-contained; no repo needed."
    echo "export LD_LIBRARY_PATH=\"$libpath\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
    echo "$envlines"
    echo "export MYK_SHELL=\"\${MYK_SHELL:-$SHELL_CMD}\""
    echo "exec \"$binpath\" \"\$@\""
  } > "$launcher"
  chmod +x "$launcher"

  # 2. personalized icon → hicolor scalable (KDE resolves SVG by name)
  command cp -f "$(cfg '.desktop.icon_svg')" "$icons/$BIN.svg" 2>/dev/null || true

  # 3. .desktop entry (Name/Exec/Icon/WMClass/etc all from build.json)
  cat > "$apps/$BIN.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$(cfg '.app.product_name')
GenericName=$(cfg '.desktop.generic_name')
Comment=$(cfg '.desktop.comment')
Exec=$launcher
Icon=$BIN
Terminal=false
StartupNotify=true
StartupWMClass=$(cfg '.app.wm_class')
Categories=$(cfg '.desktop.categories')
EOF

  # 4. refresh caches (best-effort — no failure if the tools are absent)
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps" 2>/dev/null || true
  command -v gtk-update-icon-cache   >/dev/null 2>&1 && gtk-update-icon-cache -qtf "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
  log "Installed launcher + desktop entry + icon (menu/taskbar: $BIN)"
}

case "${1:-build}" in
  build)    cmd_build ;;
  dev)      cmd_dev ;;
  check)    cmd_check ;;
  run)      shift; cmd_run "${1:-}" ;;
  fetch)    cmd_fetch ;;
  install)  cmd_install ;;
  data)     sync_data ;;
  clean)    cmd_clean ;;
  vendor)   vendor ;;
  *)        echo "Usage: $0 [build|dev|check|run|fetch|install|data|clean|vendor]" ;;
esac
