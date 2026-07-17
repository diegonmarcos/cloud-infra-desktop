#!/usr/bin/env bash
# my-browser-rust-chromium — build engine.
#
# MVP strategy: build the real upstream cef-rs `cefsimple` example INSIDE its own
# workspace (where its workspace-deps resolve and `export-cef-dir` fetches the
# matching CEF). That gives a proven-good Rust + real-Chromium (BoringSSL) binary
# — the clean-fingerprint MVP — without standalone dependency surgery. We fork /
# customize (start URL, chrome bar, keybinds) on top of this baseline next.
#
# Data-driven: cef-rs repo + ref live in build.json (cef_rs.repo / cef_rs.ref).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$HERE/dist"; WORK="$HERE/.build"
NAME="my-browser-rust-chromium"; TAG="${NAME}-latest"; TARBALL="${NAME}-linux-x86_64.tar.gz"

REPO="$(jq -r '.cef_rs.repo' "$HERE/build.json")"
REF="$(jq -r '.cef_rs.ref'  "$HERE/build.json")"
EXAMPLE="$(jq -r '.cef_rs.example' "$HERE/build.json")"
CEF_DIR="$WORK/cef"; SRC="$WORK/cef-rs"

_fetch() {   # clone cef-rs @ ref + export the matching CEF into $CEF_DIR
  rm -rf "$SRC"; mkdir -p "$WORK"
  git clone --depth 1 --branch "$REF" "$REPO" "$SRC" 2>/dev/null || git clone --depth 1 "$REPO" "$SRC"
  ( cd "$SRC" && cargo run -p export-cef-dir -- --force "$CEF_DIR" )
}
_build() { export CEF_PATH="$CEF_DIR" LD_LIBRARY_PATH="$CEF_DIR:${LD_LIBRARY_PATH:-}"
  ( cd "$SRC" && cargo build -p "$EXAMPLE" --release ) ; }

cmd="${1:-help}"
case "$cmd" in
  fetch)   _fetch ;;
  build)   [ -d "$SRC" ] || _fetch; _build ;;
  run)     "$0" build; CEF_PATH="$CEF_DIR" LD_LIBRARY_PATH="$CEF_DIR" "$SRC/target/release/$EXAMPLE" "${2:-}" ;;
  clean)   rm -rf "$WORK" "$DIST" ;;

  release) "$0" build
    mkdir -p "$DIST/bundle"
    cp "$SRC/target/release/$EXAMPLE" "$DIST/bundle/$NAME"
    cp -r "$CEF_DIR"/. "$DIST/bundle/" 2>/dev/null || true   # libcef.so + resources for a portable run
    # baked homepage (copied from qute's dashboard → 2_configs/, committed)
    cp "$HERE/2_configs/my-browser-chromium-homepage.html" "$DIST/bundle/" 2>/dev/null || true
    # launcher: sets CEF paths + opens the baked homepage (cefsimple honours --url=)
    cat > "$DIST/bundle/my-browser" <<'LAUNCH'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
export CEF_PATH="$HERE" LD_LIBRARY_PATH="$HERE"
exec "$HERE/my-browser-rust-chromium" --url="file://$HERE/my-browser-chromium-homepage.html" "$@"
LAUNCH
    chmod +x "$DIST/bundle/my-browser"
    tar -C "$DIST/bundle" -czf "$DIST/$TARBALL" .
    echo "staged $DIST/$TARBALL" ;;

  gh-release)
    gh release view "$TAG" >/dev/null 2>&1 \
      || gh release create "$TAG" --title "$NAME (rolling)" --notes "Rust + real-Chromium (CEF) MVP — upstream cefsimple baseline"
    gh release upload "$TAG" "$DIST/$TARBALL" --clobber ;;

  ghcr-push)   # oras rejects absolute paths → push from inside $DIST with a relative name
    ( cd "$DIST" && oras push "ghcr.io/diegonmarcos/${NAME}:latest" "${TARBALL}:application/gzip" ) ;;

  ship)    "$0" release && "$0" gh-release && "$0" ghcr-push ;;
  help|*)  echo "usage: build.sh {fetch|build|run [URL]|release|gh-release|ghcr-push|ship|clean}" ;;
esac
