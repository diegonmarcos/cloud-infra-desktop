#!/usr/bin/env bash
set -euo pipefail
ENGINE="@engine@"
[ -x "$ENGINE" ] || { echo "redroid engine not found at $ENGINE (clone ~/git/cloud-unix)"; exit 1; }
# The image is BAKED (apps + layout + theme already inside it), so runtime is just
# pull+run+mirror — NO provision/install step. First `up` pulls the GHCR image.
# `up` is GUI-bound in the engine: it boots the backend, attaches scrcpy in
# the foreground, and stops the container when the GUI closes (no GUI => no
# running redroid). So the wrapper just execs it — NEVER `up && scrcpy`, which
# would double-launch scrcpy on a torn-down container.
case "${1:-up}" in
  up|""|mirror)  exec "$ENGINE" up ;;
  down)          exec "$ENGINE" down ;;
  *)             exec "$ENGINE" "$@" ;;
esac
