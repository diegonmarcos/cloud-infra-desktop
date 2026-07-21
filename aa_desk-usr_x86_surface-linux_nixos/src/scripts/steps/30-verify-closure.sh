#!/usr/bin/env bash
# STEP 30 — prove the target closure is COMPLETE before activating.
# The diff is computed against the committed have-paths inventory; a local GC
# can silently invalidate it. `nix-store -qR` walks the full reference graph
# from the nix DB and fails on any missing dependency — catch a broken
# closure BEFORE it becomes a broken system.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sys="$(target_sys)" || { error "no target (run step 10)"; exit 1; }
[ -d "$sys" ] || { error "target dir missing: $sys"; exit 1; }
if ! nix-store -qR "$sys" >/dev/null 2>&1; then
    error "closure INCOMPLETE: $sys has missing dependencies (likely GC-stale inventory)."
    error "Fix: nix-store -qR /nix/var/nix/profiles/system | sort > dist-ci-have/have-paths.txt"
    error "     commit+push, rerun CI, switch again."
    exit 1
fi
log "Closure verified complete: $sys"
