#!/usr/bin/env bash
set -euo pipefail
BINARY="@binary@"
ENGINE="@engine@"
# REPO ENGINE FIRST, baked binary as the fallback — reversed 2026-08-26.
#
# It used to prefer $BINARY (the self-contained launcher docker-cp'd out of the GHCR
# image by `build.sh install`). That silently pinned this machine to whatever engine
# was baked into the last image that BUILT, so every repo-side change was invisible
# until CI went green AND `install` was re-run by hand. Live failure: `up mobile` (the
# tablet/phone launch forms) reached an Aug-22 baked launcher that parses its argument
# as a display MODE, matched no case, and just reused the running tablet session — the
# Phone launcher looked identical to the Tablet one, with no error anywhere. The image
# had in fact been failing to build for two days on a stale APK pin, so the staleness
# was unbounded and nothing surfaced it.
#
# On a machine that HAS the repo, the repo is the source of truth; the baked binary
# exists for machines that don't (the portable artifact). Trade-off, accepted: the
# launcher now tracks the working tree, so a half-finished edit to build.sh is what the
# desktop icon runs. That is the correct failure for a machine you develop the engine on
# — it is visible immediately instead of two days later.
if [ -x "$ENGINE" ]; then RUN="$ENGINE"
elif [ -x "$BINARY" ]; then RUN="$BINARY"
else echo "waydroid launcher not installed and engine not found — run: waydroid-container install (or clone ~/git/cloud-unix)"; exit 1; fi
case "${1:-up}" in
  up|"")  shift 2>/dev/null || true; exec "$RUN" up "$@" ;;
  *)      exec "$RUN" "$@" ;;
esac
