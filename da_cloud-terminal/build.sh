#!/usr/bin/env bash
# da_cloud-terminal build/publish/pull — data-driven from build.json (.release).
#
#   build.sh build         compile + icons + gen Tools profile + emit launchers (local)
#   build.sh install       build, then symlink launchers into ~/.local/bin
#   build.sh launch <p>    build, then launch profile <p> --show
#   build.sh launch-all    build, then launch every profile tray
#   build.sh package       build → stage payload → dist/release/cloud-terminal.tar.zst (+version)   [CI]
#   build.sh oras-push     push the tarball to ghcr.io/<ns>/<image>:<tags>                          [CI]
#   build.sh gh-release    upload tarball + version to the rolling GH Release                       [CI]
#   build.sh pull          device: version-guarded download from the GH Release, extract, emit launchers
#
# CI ships only the PAYLOAD (no launchers); launchers are emitted on the machine
# that will run them so the local electron/node nix-store paths always resolve.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
DIST="$ROOT/dist"
CMD="${1:-build}"
JQ="$(command -v jq || true)"
BJSON="$ROOT/build.json"

rel() { [ -n "$JQ" ] || { echo "ERROR: jq required"; exit 1; }; "$JQ" -r "$1 // empty" "$BJSON"; }

NODE_BIN="$(command -v node || true)"
FISH_BIN="$(command -v fish 2>/dev/null || echo bash)"

resolve_electron() { ls /nix/store/*electron-3[0-9]*/bin/electron 2>/dev/null | sort -V | tail -1 || command -v electron 2>/dev/null || true; }

# ── emit_launchers <app_dir> <bin_dir> ───────────────────────────────────────
# Generate one launcher per profile JSON, pointing at <app_dir>, resolving the
# LOCAL electron + node at emit time. Used by build (app_dir=ROOT) and pull
# (app_dir=installed share dir).
emit_launchers() {
  local app="$1" bindir="$2" el; el="$(resolve_electron)"
  [ -z "$el" ]       && { echo "ERROR: electron not found in /nix/store or PATH"; exit 1; }
  [ -z "$NODE_BIN" ] && { echo "ERROR: node not found"; exit 1; }
  mkdir -p "$bindir"
  local json name launcher
  for json in "$app/src/data/"profile-*.json; do
    name="$(basename "$json" .json | sed 's/^profile-//')"
    launcher="$bindir/cloud-terminal-$name"
    cat > "$launcher" <<LAUNCHER
#!/usr/bin/env bash
export CT_PROFILE="$name"
export CT_PROFILES_DIR="$app/src/data"
export CT_ICON="$app/src/assets/$name.png"
export CT_PANEL="$app/lib/panel.html"
export CT_BIN_DIR="$bindir"
export CT_NODE="\${CT_NODE:-$NODE_BIN}"
export CT_PTY_SERVER="\${CT_PTY_SERVER:-$app/src/scripts/pty-server.js}"
export CT_SHELL="\${CT_SHELL:-$FISH_BIN}"
export ELECTRON_OZONE_PLATFORM_HINT="\${ELECTRON_OZONE_PLATFORM_HINT:-auto}"
exec "$el" "$app/src/scripts/dist/main.js" --class="cloud-terminal-$name" "\$@"
LAUNCHER
    chmod +x "$launcher"
    echo "   → $launcher"
  done
}

build() {
  echo "→ installing deps (xterm + node-pty + typescript)..."
  ( cd "$ROOT" && npm install --no-audit --no-fund --silent )
  # tsc: prefer the project-local one (from npm ci) so CI needs no global install.
  local TSC MAGICK; TSC="$ROOT/node_modules/.bin/tsc"; [ -x "$TSC" ] || TSC="$(command -v tsc || true)"
  [ -z "$TSC" ] && { echo "ERROR: tsc not found (add typescript devDep or install tsc)"; exit 1; }
  # ImageMagick 7 = `magick`; IM6 (ubuntu) = `convert`. Both take the same args here.
  MAGICK="$(command -v magick || command -v convert || true)"
  [ -z "$MAGICK" ] && { echo "ERROR: magick/convert not found"; exit 1; }
  echo "→ generating Tools profile from DTK registry..."
  bash "$SRC/scripts/gen-tools-profile.sh"
  echo "→ compiling TypeScript..."
  ( cd "$SRC/scripts" && "$TSC" )
  echo "→ converting icons ($MAGICK)..."
  local svg name
  for svg in "$SRC/assets/"*.svg; do
    name="$(basename "$svg" .svg)"
    "$MAGICK" -background none "$svg" -resize 128x128 -define png:color-type=6 "PNG32:$SRC/assets/$name.png" 2>/dev/null
  done
  echo "→ emitting launchers (local electron)..."
  emit_launchers "$ROOT" "$DIST/bin"
  echo "done."
}

# ── package: stage payload (from build.json) → tar.zst + version  [CI] ────────
package() {
  build
  local rdir="$DIST/release" pdir="$DIST/release/payload"
  rm -rf "$rdir"; mkdir -p "$pdir"
  local ver; ver="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
  echo "→ staging payload (version $ver)..."
  local pat
  rel '.release.payload[]' | while IFS= read -r pat; do
    ( cd "$ROOT" && for m in $pat; do
        [ -e "$m" ] || continue
        tar -cf - "$m" | tar -C "$pdir" -xf -
      done )
    echo "   + $pat"
  done
  printf '%s\n' "$ver" > "$pdir/cloud-terminal.version"
  local asset; asset="$DIST/release/$(rel '.release.gh_release.asset')"
  ( cd "$pdir" && tar -cf - . | zstd -T0 -19 -q -o "$asset" )
  cp "$pdir/cloud-terminal.version" "$DIST/release/$(rel '.release.gh_release.version_asset')"
  echo "→ packaged: $asset ($(du -h "$asset" | cut -f1)) version=$ver"
}

oras_push() {
  local reg ns img mt; reg="$(rel '.release.ghcr.registry')"; ns="$(rel '.release.ghcr.namespace')"
  img="$(rel '.release.ghcr.image')"; mt="$(rel '.release.ghcr.media_type')"
  local ver; ver="$(cat "$DIST/release/payload/cloud-terminal.version")"
  local asset; asset="$(rel '.release.gh_release.asset')"
  ( cd "$DIST/release"
    rel '.release.ghcr.tags[]' | sed "s/{sha}/$ver/" | while IFS= read -r tag; do
      echo "→ oras push $reg/$ns/$img:$tag"
      oras push "$reg/$ns/$img:$tag" "$asset:$mt" --annotation "org.opencontainers.image.revision=$ver"
    done )
}

gh_release() {
  local tag asset vasset; tag="$(rel '.release.gh_release.rolling_tag')"
  asset="$DIST/release/$(rel '.release.gh_release.asset')"
  vasset="$DIST/release/$(rel '.release.gh_release.version_asset')"
  gh release create "$tag" --title "$tag" --target "${GITHUB_SHA:-main}" --notes "rolling cloud-terminal build" --latest 2>/dev/null || true
  gh release upload "$tag" "$asset" "$vasset" --clobber
  echo "→ uploaded to GH release '$tag'"
}

# ── pull: device-side, version-guarded install from the GH Release ────────────
pull() {
  local repo tag asset vasset share bindir
  repo="$(rel '.release.gh_release.repo')"; tag="$(rel '.release.gh_release.rolling_tag')"
  asset="$(rel '.release.gh_release.asset')"; vasset="$(rel '.release.gh_release.version_asset')"
  share="$HOME/$(rel '.release.install.share_dir')"; bindir="$HOME/$(rel '.release.install.bin_dir')"
  local base="https://github.com/$repo/releases/download/$tag"
  local marker="$share/.installed"
  echo "→ checking latest cloud-terminal version..."
  local latest; latest="$(curl -fsSL "$base/$vasset" 2>/dev/null || echo "")"
  [ -z "$latest" ] && { echo "   no published version (asset missing) — skipping"; return 0; }
  local cur=""; [ -f "$marker" ] && cur="$(cat "$marker")"
  if [ "$latest" = "$cur" ]; then echo "   up-to-date ($cur)"; return 0; fi
  echo "→ pulling $latest (was '${cur:-none}')..."
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "$base/$asset" -o "$tmp/$asset" || { echo "   download failed"; rm -rf "$tmp"; return 1; }
  rm -rf "$share"; mkdir -p "$share"
  zstd -dc "$tmp/$asset" | tar -C "$share" -xf -
  rm -rf "$tmp"
  echo "→ emitting launchers → $bindir"
  emit_launchers "$share" "$bindir"
  printf '%s\n' "$latest" > "$marker"
  echo "→ installed cloud-terminal $latest"
}

case "$CMD" in
  build)       build ;;
  install)     build; emit_launchers "$ROOT" "$HOME/.local/bin" ;;
  package)     package ;;
  oras-push)   oras_push ;;
  gh-release)  gh_release ;;
  pull)        pull ;;
  launch)      build; "$DIST/bin/cloud-terminal-${2:-nix-flakes}" --show & ;;
  launch-all)  build; for l in "$DIST/bin/"cloud-terminal-*; do "$l" & done ;;
  *) echo "unknown command: $CMD"; exit 1 ;;
esac
