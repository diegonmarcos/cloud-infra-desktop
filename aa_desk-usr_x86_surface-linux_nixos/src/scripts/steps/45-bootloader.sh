#!/usr/bin/env bash
# STEP 45 — refresh + verify the boot menu against the new generation
# (aa_bootloader deploy-all + verify-boot). Warns loudly on failure but never
# fails the pipeline — the system IS switched; only reboot safety is at stake.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

bl="$REPO_DIR/../aa_bootloader"
if [ ! -x "$bl/build.sh" ]; then
    warn "aa_bootloader/build.sh not found — boot menu NOT refreshed."
    warn "Run before reboot:  cd ../aa_bootloader && sudo ./build.sh deploy-all && sudo ./build.sh verify-boot"
    exit 0
fi
log "Refreshing boot menu (aa_bootloader deploy-all)…"
if ( cd "$bl" && sudo bash ./build.sh deploy-all ); then
    if ( cd "$bl" && sudo bash ./build.sh verify-boot ); then
        log "Boot menu refreshed + verified — SAFE TO REBOOT."
    else
        warn "deploy-all OK but verify-boot NOT green — inspect before rebooting."
    fi
else
    warn "aa_bootloader deploy-all errored — boot menu may be stale."
fi
exit 0
