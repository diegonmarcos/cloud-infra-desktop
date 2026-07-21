#!/usr/bin/env bash
# STEP 40 — activate: set the system profile + switch-to-configuration.
# Fast, no eval. This is the only step that changes the running system.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sys="$(target_sys)" || { error "no target (run step 10)"; exit 1; }
log "Activating $sys…"
sudo nix-env -p /nix/var/nix/profiles/system --set "$sys" || { error "profile set failed"; exit 1; }
sudo "$sys/bin/switch-to-configuration" switch || { error "switch-to-configuration failed"; exit 1; }
log "Activation done — generation advanced."
