#!/usr/bin/env bash
# my-browser-rust-chromium — thin engine wrapper (skeleton).
# Mirrors the da_my-browser-qute verb surface. Real steps land as phases complete.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmd="${1:-help}"

case "$cmd" in
  build)   cd "$HERE/src" && cargo build --release ;;   # needs libcef pinned in flake first
  run)     cd "$HERE/src" && cargo run ;;               # skeleton: prints status, no CEF yet
  fmt)     cd "$HERE/src" && cargo fmt ;;
  clean)   cd "$HERE/src" && cargo clean ;;
  release) echo "TODO: nix-bundle portable artifact (mirror da_my-browser-qute)"; exit 1 ;;
  help|*)  echo "usage: build.sh {build|run|fmt|clean|release}"
           echo "status: SKELETON — see README.md phase table before expecting a browser." ;;
esac
