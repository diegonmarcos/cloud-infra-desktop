#!/usr/bin/env bash
set -euo pipefail
BINARY="@binary@"
ENGINE="@engine@"
if [ -x "$BINARY" ]; then RUN="$BINARY"
elif [ -x "$ENGINE" ]; then RUN="$ENGINE"
else echo "waydroid launcher not installed and engine not found — run: waydroid-container install (or clone ~/git/cloud-unix)"; exit 1; fi
case "${1:-up}" in
  up|"")  shift 2>/dev/null || true; exec "$RUN" up "$@" ;;
  *)      exec "$RUN" "$@" ;;
esac
