#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Cloud Terminal — Tauri (Rust) build dispatcher                    ║
# ║                                                                    ║
# ║ Port of the Electron app to Tauri. Toolchain (rust/cargo/          ║
# ║ cargo-tauri/webkitgtk/node/magick) ALL comes from flake.nix —      ║
# ║ never assume the host has them. Every build call goes through      ║
# ║ `nix develop` (in_nix), same law as the ea_cloud-* Android apps.   ║
# ║                                                                    ║
# ║   build.sh vendor    copy xterm assets node_modules → frontend/    ║
# ║   build.sh icons     generate src-tauri/icons from src/assets      ║
# ║   build.sh build     vendor + icons + cargo tauri build (release)  ║
# ║   build.sh dev       cargo tauri dev (hot-reload)                  ║
# ║   build.sh check     cargo check (fast compile validation)         ║
# ║   build.sh run <p>   run the built binary for profile <p>          ║
# ║   build.sh shell     enter the Nix devShell                       ║
# ║   build.sh clean     rm target/ dist/ frontend/vendor              ║
# ║                                                                    ║
# ║ TODO(release): ship/oras-push/gh-release/pull for the Tauri        ║
# ║   artifact (binary/AppImage) — artifact model differs from the      ║
# ║   old electron tar.zst payload; port once `build` is verified.      ║
# ║                                                                    ║
# ║ NEVER bypass this script for build operations.                     ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
TAURI="$ROOT/src-tauri"
FRONTEND="$ROOT/frontend"
DIST="$ROOT/dist"
CMD="${1:-build}"

# Cap compile parallelism — the GTK/WebKit-sys crates + linker peak hard on
# RAM; the default (one job per core) OOM-kills ld (exit 137) on 8–16 GB
# laptops. Override with CARGO_BUILD_JOBS=<n> for beefier machines / CI.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
# Drop debuginfo on the dev/check profile — debug=2 (default) is the single
# biggest rustc peak-memory driver; we don't debug the GTK-sys deps.
export CARGO_PROFILE_DEV_DEBUG="${CARGO_PROFILE_DEV_DEBUG:-0}"

log()    { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
errlog() { printf "\033[0;31m[%s] ERROR: %s\033[0m\n" "$(date '+%H:%M:%S')" "$1" >&2; }

# Nix-wrapped invocation — reproducible toolchain from flake.nix.
in_nix() {
  if [ "${BYPASS_NIX:-0}" = "1" ]; then
    "$@"
  else
    command -v nix >/dev/null 2>&1 || { errlog "nix not on PATH; install nix or set BYPASS_NIX=1"; exit 1; }
    nix develop "$ROOT" --command "$@"
  fi
}

# ── vendor: copy xterm runtime assets into frontend/vendor (no bundler) ──
# The renderer loads these via <script>/<link>, so no node require + no build
# step for the webview. node_modules populated by `npm install` in the shell.
vendor() {
  log "vendoring xterm assets → frontend/vendor"
  in_nix npm --prefix "$ROOT" install --no-audit --no-fund --silent \
    @xterm/xterm@^6.0.0 @xterm/addon-fit@^0.11.0
  local nm="$ROOT/node_modules"
  mkdir -p "$FRONTEND/vendor"
  cp "$nm/@xterm/xterm/lib/xterm.js"            "$FRONTEND/vendor/xterm.js"
  cp "$nm/@xterm/xterm/css/xterm.css"           "$FRONTEND/vendor/xterm.css"
  cp "$nm/@xterm/addon-fit/lib/addon-fit.js"    "$FRONTEND/vendor/addon-fit.js"
  log "  → frontend/vendor/{xterm.js,xterm.css,addon-fit.js}"
}

# ── icons: tauri.conf.json expects icons/{32x32,128x128,icon}.png ──
# Generated from the primary profile SVG so we keep ONE source of truth.
icons() {
  log "generating tauri icons from src/assets"
  local svg; svg="$(ls "$SRC/assets/"*.svg 2>/dev/null | head -1)"
  [ -z "$svg" ] && { errlog "no SVG in src/assets to build icons from"; exit 1; }
  mkdir -p "$TAURI/icons"
  in_nix magick -background none "$svg" -resize 32x32   -define png:color-type=6 "PNG32:$TAURI/icons/32x32.png"
  in_nix magick -background none "$svg" -resize 128x128 -define png:color-type=6 "PNG32:$TAURI/icons/128x128.png"
  in_nix magick -background none "$svg" -resize 512x512 -define png:color-type=6 "PNG32:$TAURI/icons/icon.png"
  # Per-profile tray PNGs the app loads at runtime (CT_ASSETS_DIR).
  local s name
  for s in "$SRC/assets/"*.svg; do
    name="$(basename "$s" .svg)"
    in_nix magick -background none "$s" -resize 128x128 -define png:color-type=6 "PNG32:$SRC/assets/$name.png"
  done
}

build() {
  vendor
  icons
  log "cargo tauri build (release)"
  ( cd "$TAURI" && in_nix cargo tauri build )
  mkdir -p "$DIST"
  cp "$TAURI/target/release/cloud-terminal" "$DIST/cloud-terminal" 2>/dev/null || true
  log "→ binary: $TAURI/target/release/cloud-terminal"
  log "→ bundles: $TAURI/target/release/bundle/"
}

case "$CMD" in
  vendor) vendor ;;
  icons)  icons ;;
  build)  build ;;
  dev)    vendor; icons; ( cd "$TAURI" && in_nix cargo tauri dev ) ;;
  check)  vendor; icons; ( cd "$TAURI" && in_nix cargo check ) ;;
  run)    CT_APP_DIR="$SRC" CT_ASSETS_DIR="$SRC/assets" CT_PROFILES_DIR="$SRC/data" \
            CT_PROFILE="${2:-nix-flakes}" "$TAURI/target/release/cloud-terminal" --show ;;
  shell)  exec nix develop "$ROOT" ;;
  clean)  rm -rf "$TAURI/target" "$DIST" "$FRONTEND/vendor" "$ROOT/node_modules"; log "cleaned" ;;
  *)      errlog "unknown command: $CMD"; exit 1 ;;
esac
