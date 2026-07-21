#!/usr/bin/env bash
# STEP 20 — import the closure diff into /nix/store (no eval, no build).
# Empty diff file = laptop already has every path (valid state, exit 0).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

nar="$DIFF_DL/closure-diff.nar.zst"
[ -f "$nar" ] || { error "no $nar — run step 10 first"; exit 1; }

if [ ! -s "$nar" ]; then
    log "Diff is empty — every target path already present locally."
    exit 0
fi
log "Importing closure DIFF ($(stat -c%s "$nar" | awk '{printf "%.1f MB", $1/1048576}'))…"
zstd -d -c "$nar" | sudo nix-store --import >/dev/null || { error "diff import failed"; exit 1; }
log "Diff imported."
