#!/usr/bin/env bash
# da_cloud-terminal build script — no nix required
# Outputs: dist/bin/cloud-terminal-<profile>  (executable launchers)
# Usage:   build.sh [build]        compile + icons + launchers   (default)
#          build.sh launch <p>     build, then launch profile <p> with --show
#          build.sh launch-all     build, then launch every profile tray
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
DIST="$ROOT/dist"
CMD="${1:-build}"

# ── find tools ────────────────────────────────────────────────────────────────
TSC="$(command -v tsc)"
MAGICK="$(command -v magick)"
ELECTRON="$(ls /nix/store/*electron-3[0-9]*/bin/electron 2>/dev/null | sort -V | tail -1)"
if [[ -z "$ELECTRON" ]]; then
  ELECTRON="$(command -v electron 2>/dev/null || true)"
fi
[[ -z "$TSC"      ]] && { echo "ERROR: tsc not found";      exit 1; }
[[ -z "$MAGICK"   ]] && { echo "ERROR: magick not found";   exit 1; }
[[ -z "$ELECTRON" ]] && { echo "ERROR: electron not found"; exit 1; }

NODE="$(command -v node)"
[[ -z "$NODE" ]] && { echo "ERROR: node not found"; exit 1; }

build() {
  echo "→ tsc:      $TSC"
  echo "→ magick:   $MAGICK"
  echo "→ electron: $ELECTRON"
  echo "→ node:     $NODE"

  echo "→ installing deps (xterm + node-pty)..."
  ( cd "$ROOT" && npm install --no-audit --no-fund --silent )

  echo "→ compiling TypeScript..."
  ( cd "$SRC/scripts" && "$TSC" )
  echo "   compiled → $SRC/scripts/dist/main.js"

  echo "→ converting icons..."
  for svg in "$SRC/assets/"*.svg; do
    name="$(basename "$svg" .svg)"
    "$MAGICK" -background none "$svg" -resize 128x128 -define png:color-type=6 "PNG32:$SRC/assets/$name.png" 2>/dev/null
    echo "   $svg → $SRC/assets/$name.png"
  done

  echo "→ emitting launchers..."
  mkdir -p "$DIST/bin"
  for json in "$SRC/data/"profile-*.json; do
    name="$(basename "$json" .json | sed 's/^profile-//')"
    launcher="$DIST/bin/cloud-terminal-$name"
    cat > "$launcher" <<LAUNCHER
#!/usr/bin/env bash
export CT_PROFILE="$name"
export CT_PROFILES_DIR="$SRC/data"
export CT_ICON="$SRC/assets/$name.png"
export CT_PANEL="$ROOT/lib/panel.html"
export CT_BIN_DIR="$DIST/bin"
export CT_NODE="\${CT_NODE:-$NODE}"
export CT_PTY_SERVER="\${CT_PTY_SERVER:-$SRC/scripts/pty-server.js}"
export CT_SHELL="\${CT_SHELL:-$(command -v fish 2>/dev/null || echo bash)}"
export ELECTRON_OZONE_PLATFORM_HINT="\${ELECTRON_OZONE_PLATFORM_HINT:-auto}"
# --class sets the Wayland app_id / X11 WM_CLASS → deterministic KWin resourceClass
# so default-session-launcher.sh can position this window.
exec "$ELECTRON" "$SRC/scripts/dist/main.js" --class="cloud-terminal-$name" "\$@"
LAUNCHER
    chmod +x "$launcher"
    echo "   → $launcher"
  done
  echo "done."
}

install_bins() {
  build
  local bindir="$HOME/.local/bin"
  mkdir -p "$bindir"
  for l in "$DIST/bin/"cloud-terminal-*; do
    ln -sf "$l" "$bindir/$(basename "$l")"
    echo "   linked → $bindir/$(basename "$l")"
  done
  echo "installed to $bindir (on PATH)."
}

case "$CMD" in
  build) build ;;
  install) install_bins ;;
  launch)
    build
    p="${2:-nix-flakes}"
    echo "→ launching cloud-terminal-$p"
    "$DIST/bin/cloud-terminal-$p" --show &
    ;;
  launch-all)
    build
    for l in "$DIST/bin/"cloud-terminal-*; do
      echo "→ launching $(basename "$l")"
      "$l" &
    done
    ;;
  *) echo "unknown command: $CMD"; exit 1 ;;
esac
