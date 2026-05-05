#!/usr/bin/env bash
# Flash GrapheneOS factory image declared in build.json.device.
# Image must already be in dist/ via 'nix build src#factory' (run by `build.sh build`).
set -euo pipefail
source "$REPO_ROOT/lib/_engine.sh"

ROM=$(jq -r '.device.rom' "$BUILD_JSON")
CODENAME=$(jq -r '.device.codename' "$BUILD_JSON")
BUILD=$(jq -r '.device.rom_pinned_build' "$BUILD_JSON")

[[ "$ROM" == "grapheneos" ]] || die "Only grapheneos supported (got: $ROM)"

IMG="$REPO_ROOT/dist/factory/${CODENAME}-factory-${BUILD}.zip"
[[ -f "$IMG" ]] || die "Factory image missing: $IMG  (run 'nix build src#factory' first)"

command -v fastboot >/dev/null || die "fastboot required"

log "Rebooting device into bootloader..."
adb reboot bootloader || true
sleep 5

log "Unlocking bootloader (manual confirm on device)..."
fastboot flashing unlock || true

log "Extracting + flashing $IMG ..."
WORK=$(mktemp -d) ; trap 'rm -rf "$WORK"' EXIT
unzip -qo "$IMG" -d "$WORK"
( cd "$WORK"/*/ && bash flash-all.sh )

log "Re-locking bootloader with GrapheneOS keys..."
fastboot flashing lock

log "Done. Phone will reboot. Re-run 'build.sh configure' once ADB authorised."
