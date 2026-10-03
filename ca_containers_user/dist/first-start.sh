#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ first-start — runtime home-manager switch for the deb-nix image  ║
# ╚══════════════════════════════════════════════════════════════════╝
# The diego@cli flake lives in the PRIVATE repo cloud-me_configs. This image
# is published to a PUBLIC GHCR namespace, so nothing private may be cloned at
# build time (see build.json::_doc_private_repos). Instead, on container start
# we clone it with the deploy key provided at runtime and run the switch once.
#
# Key lookup (first match wins; the key itself is never printed):
#   1. $ME_CONFIGS_DEPLOY_KEY_FILE  - path to a mounted read-only deploy key
#   2. whatever ssh already uses     - ssh-agent / ~/.ssh from the mounted $HOME
# Never fatal: if the clone or switch fails, the image's baseline
# `nix profile` toolset is still there and the shell starts normally.
set -u

REPO_URL="${ME_CONFIGS_REPO:-git@github.com:diegonmarcos/cloud-me_configs.git}"
REPO_DIR="${ME_CONFIGS_DIR:-$HOME/git/cloud-me_configs}"
FLAKE_DIR="$REPO_DIR/A_CONFIGS-USER/a1-diego-user/nix-hm-flakes/ba_flakes_desktop/src"
HM_CONFIG="${HM_CONFIG:-diego@cli}"
STAMP="$HOME/.local/state/diego-image/hm-switched"

log() { printf '[first-start] %s\n' "$*" >&2; }

run() {
    [ "${SKIP_HM_SWITCH:-0}" = "1" ] && { log "SKIP_HM_SWITCH=1, skipping"; return 0; }
    [ -f "$STAMP" ] && return 0
    [ -r "$HOME/.nix-profile/etc/profile.d/nix.sh" ] && . "$HOME/.nix-profile/etc/profile.d/nix.sh"

    if [ -n "${ME_CONFIGS_DEPLOY_KEY_FILE:-}" ]; then
        if [ -r "$ME_CONFIGS_DEPLOY_KEY_FILE" ]; then
            export GIT_SSH_COMMAND="ssh -i $ME_CONFIGS_DEPLOY_KEY_FILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
        else
            log "ME_CONFIGS_DEPLOY_KEY_FILE is set but not readable; trying default ssh identity"
        fi
    fi
    : "${GIT_SSH_COMMAND:=ssh -o StrictHostKeyChecking=accept-new}"
    export GIT_SSH_COMMAND

    if [ -d "$REPO_DIR/.git" ]; then
        git -C "$REPO_DIR" pull --ff-only -q >/dev/null 2>&1 || log "pull failed; using existing checkout"
    else
        mkdir -p "$(dirname "$REPO_DIR")"
        if ! git clone --depth 1 -q "$REPO_URL" "$REPO_DIR" >/dev/null 2>&1; then
            log "could not clone cloud-me_configs (no deploy key?); keeping baseline toolset"
            return 0
        fi
    fi

    [ -d "$FLAKE_DIR" ] || { log "flake dir missing in checkout: $FLAKE_DIR"; return 0; }
    log "home-manager switch --flake .#$HM_CONFIG (first start only)"
    if ( cd "$FLAKE_DIR" && nix run home-manager/release-24.11 -- switch --flake ".#$HM_CONFIG" --impure ); then
        mkdir -p "$(dirname "$STAMP")" && date -u +%FT%TZ > "$STAMP"
        log "HOME-MANAGER: SUCCESS"
    else
        log "HOME-MANAGER: FAILED; baseline toolset stays active, will retry next start"
    fi
}

run
exec "$@"
