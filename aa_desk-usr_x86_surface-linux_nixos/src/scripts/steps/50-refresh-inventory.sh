#!/usr/bin/env bash
# STEP 50 — self-maintain: regenerate + push the have-paths inventory from the
# NEW generation so CI's next diff stays minimal. Best-effort (warn, never
# fail the pipeline — the switch already succeeded).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mkdir -p "$(dirname "$HAVE")"
nix-store -qR /nix/var/nix/profiles/system | sort > "$HAVE"
log "Inventory: $(wc -l < "$HAVE") paths"
( cd "$REPO_DIR" \
  && git add "$HAVE" \
  && git commit -q -m "have-paths: refresh after switch to $(basename "$(active_sys)")" -- "$HAVE" \
  && git push -q origin main ) 2>/dev/null \
  && log "have-paths refreshed + pushed" \
  || warn "have-paths not pushed (nothing changed, or push failed — push manually if needed)"
exit 0
