#!/usr/bin/env bash
# STEP 10 — fetch the closure-diff artifact from the latest successful CI run.
# DIFF-ONLY POLICY: full closure downloads (7GB GHCR mono-layer / nar.zst) are
# FORBIDDEN on this laptop; this artifact is the sole delivery mechanism.
# Writes: dist-ci-diff-dl/{closure-diff.nar.zst,toplevel.name}
#         dist-ci/toplevel.name   (canonical hand-off for later steps)
# Exit:   0 fetched · 3 already-active (pipeline may stop, success) · 1 fail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v gh >/dev/null 2>&1 || { error "gh CLI missing"; exit 1; }

run=$(cd "$REPO_DIR" && gh run list \
    --workflow ship_nix-flakes_desktop_nixos.yaml --status success \
    --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)
[ -n "$run" ] || { error "no successful CI run found"; exit 1; }

rm -rf "$DIFF_DL"; mkdir -p "$DIFF_DL"
log "Fetching closure-diff artifact from CI run $run…"
(cd "$REPO_DIR" && gh run download "$run" -n nixos-surface-closure-diff -D "$DIFF_DL") \
    || { error "closure-diff artifact unavailable on run $run — rerun CI (full downloads are FORBIDDEN)"; exit 1; }

mkdir -p "$ART"
cp "$DIFF_DL/toplevel.name" "$ART/toplevel.name"
sys="$(target_sys)"
log "Target: $sys"
if [ "$sys" = "$(active_sys)" ]; then
    log "Target is already the ACTIVE generation — nothing to switch."
    exit 3
fi
exit 0
