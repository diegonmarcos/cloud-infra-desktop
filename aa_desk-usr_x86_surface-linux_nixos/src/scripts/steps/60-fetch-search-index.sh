#!/usr/bin/env bash
# STEP 60 — install the CI-built store filename index for KDE/KRunner search.
#
# WHY THIS EXISTS AT ALL: KDE's own indexer (baloo) keys every document by
# (device, inode), so an index built anywhere but this exact filesystem is
# structurally meaningless — that is why baloo is disabled outright
# (modules/programs/disable-baloo.nix) and why this artifact is not one.
# plocate's DB is keyed by PATH; /nix/store paths are content-addressed and
# byte-identical on every machine, so CI's index transplants verbatim.
#
# Net effect: KDE search covers the whole system closure with ZERO indexing
# ever running on this 8GB laptop. The index is refreshed only by a switch,
# which is also exactly when the store contents change.
#
# NOT diffed/layered like the closure (steps 10/20): measured ~1.5MB for a
# ~240k-file closure. The have/want machinery exists for GB-scale transfers.
#
# Writes: $XDG_DATA_HOME/store-search/store.db
# Exit:   ALWAYS 0 — search is a convenience; a failure here must never mark an
#         otherwise-good switch as failed. Problems are logged, not raised.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/store-search"
DL_DIR="$ART-index-dl"   # runtime download, cloud-data (see lib.sh)

command -v gh >/dev/null 2>&1 || { warn "gh CLI missing — search index skipped"; exit 0; }

run=$(cd "$REPO_DIR" && gh run list \
    --workflow ship_nix-flakes_desktop_nixos.yaml --status success \
    --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)
[ -n "$run" ] || { warn "no successful CI run — search index skipped"; exit 0; }

rm -rf "$DL_DIR"; mkdir -p "$DL_DIR"
log "Fetching store search index from CI run $run…"
if ! (cd "$REPO_DIR" && gh run download "$run" -n nixos-surface-search-index -D "$DL_DIR" 2>/dev/null); then
    warn "search-index artifact unavailable on run $run — keeping existing index"
    exit 0
fi

[ -s "$DL_DIR/store.db" ] || { warn "downloaded index is empty — keeping existing"; exit 0; }

# The index describes ONE generation. If CI has since moved on, the index still
# works (store paths are immutable — old entries just point at paths that may be
# GC'd later), but say so rather than implying it is current.
if [ -f "$DL_DIR/toplevel.name" ] && [ -f "$ART/toplevel.name" ] \
   && ! cmp -s "$DL_DIR/toplevel.name" "$ART/toplevel.name"; then
    warn "index built for a different generation than the one being activated"
fi

mkdir -p "$DEST_DIR"
# Atomic swap: KRunner may be mid-query against the old DB.
cp "$DL_DIR/store.db" "$DEST_DIR/store.db.new" && mv -f "$DEST_DIR/store.db.new" "$DEST_DIR/store.db"
rm -rf "$DL_DIR"

log "Store search index installed → $DEST_DIR/store.db ($(du -h "$DEST_DIR/store.db" | cut -f1))"
exit 0
