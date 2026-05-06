#!/bin/sh
# render-kernels.sh — stage NixOS kernels/initrds into dist/boot/kernels/
#
# Walks /nix/var/nix/profiles/system{,-N-link}, follows the kernel/initrd
# symlinks for each generation + each specialisation, copies files into
# dist/boot/kernels/<hash>-<derivname>-<file>.
#
# After this runs, dist/boot/kernels/ mirrors what /boot/kernels/ should be.
# deploy is then `cp -a dist/boot/kernels/* /boot/kernels/` — no late-bound
# /nix/store reads at deploy time.
#
# Skipped gracefully if /nix/var/nix/profiles missing (multi-OS: NixOS not
# installed = no NixOS kernels to stage).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# shellcheck source=lib/log.sh
. "$ROOT_DIR/src/engine/lib/log.sh"

NIX_PROFILES="${NIX_PROFILES:-/nix/var/nix/profiles}"
DIST_KERNELS="$ROOT_DIR/dist/boot/kernels"

if [ ! -d "$NIX_PROFILES" ]; then
    log "$NIX_PROFILES not found — no NixOS kernels to stage (multi-OS: OK)"
    exit 0
fi

mkdir -p "$DIST_KERNELS"

# /nix/store/<HASH>-<NAME>/<file>  →  <HASH>-<NAME>-<file>
nix_to_boot_name() {
    target="$1"; name=${target#/nix/store/}
    echo "${name%%/*}-${name##*/}"
}

stage_one() {
    src_link="$1"
    [ -L "$src_link" ] || return 0
    target=$(readlink "$src_link") || return 0
    [ -n "$target" ] || return 0
    boot_name=$(nix_to_boot_name "$target")
    dst="$DIST_KERNELS/$boot_name"
    if [ -f "$dst" ]; then
        return 1   # already present
    fi
    cp -L "$target" "$dst"
    return 0
}

copied=0
existed=0
for sys_link in "$NIX_PROFILES/system" "$NIX_PROFILES"/system-*-link; do
    [ -e "$sys_link" ] || continue
    sys=$(readlink -f "$sys_link" 2>/dev/null) || continue
    [ -d "$sys" ] || continue

    for f in kernel initrd; do
        if stage_one "$sys/$f"; then
            copied=$((copied + 1))
        else
            existed=$((existed + 1))
        fi
    done

    if [ -d "$sys/specialisation" ]; then
        for spec in "$sys/specialisation"/*; do
            [ -d "$spec" ] || continue
            for f in kernel initrd; do
                if stage_one "$spec/$f"; then
                    copied=$((copied + 1))
                else
                    existed=$((existed + 1))
                fi
            done
        done
    fi
done

log "Staged kernels/initrds: $copied new, $existed already present → $DIST_KERNELS/"
