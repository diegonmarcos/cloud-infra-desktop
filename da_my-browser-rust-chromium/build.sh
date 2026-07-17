#!/usr/bin/env bash
# my-browser-rust-chromium — build engine.
# Cargo binary (Rust UI + CEF backend). cef-dll-sys fetches libcef at build
# time, so this compiles wherever cmake/ninja/clang + GTK/X11/NSS deps exist
# (GHA runner via apt, or the nix devshell in src/flake.nix locally).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/src"; DIST="$HERE/dist"
NAME="my-browser-rust-chromium"
TAG="${NAME}-latest"
TARBALL="${NAME}-linux-x86_64.tar.gz"
cmd="${1:-help}"

case "$cmd" in
  build)   cd "$SRC" && cargo build --release ;;
  run)     cd "$SRC" && cargo run -- "${2:-}" ;;
  fmt)     cd "$SRC" && cargo fmt ;;
  clean)   cd "$SRC" && cargo clean; rm -rf "$DIST" ;;

  release)   # compile + stage a portable tarball into dist/
    cd "$SRC" && cargo build --release
    mkdir -p "$DIST"
    cp "$SRC/target/release/$NAME" "$DIST/$NAME"
    tar -C "$DIST" -czf "$DIST/$TARBALL" "$NAME"
    echo "staged $DIST/$TARBALL" ;;

  gh-release)   # rolling GitHub Release (pullable artifact)
    gh release view "$TAG" >/dev/null 2>&1 \
      || gh release create "$TAG" --title "$NAME (rolling)" --notes "Auto-built Rust+CEF browser MVP"
    gh release upload "$TAG" "$DIST/$TARBALL" --clobber ;;

  ghcr-push)   # mirror the tarball to GHCR as an OCI artifact
    oras push "ghcr.io/diegonmarcos/${NAME}:latest" "$DIST/$TARBALL:application/gzip" ;;

  ship)      "$0" release && "$0" gh-release && "$0" ghcr-push ;;

  help|*)  echo "usage: build.sh {build|run [URL]|fmt|clean|release|gh-release|ghcr-push|ship}"
           echo "status: MVP — needs cef build deps (nix develop src, or CI installs via apt)." ;;
esac
