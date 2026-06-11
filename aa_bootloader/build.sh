#!/bin/sh
# aa_bootloader/build.sh — orchestrator for the boot SoT
# POSIX. Run from any OS that mounts the LUKS pool.
#
# One engine, one SoT (src/boot.json). rEFInd is the default loader, GRUB is
# co-installed as fallback — both built and deployed in parallel by default.
# Per-target verbs (build-X, deploy-X) exist for surgical re-runs.
#
# Usage:
#   ./build.sh build-all          # render every engine into dist/
#   ./build.sh build-refind       # render only rEFInd artifacts
#   ./build.sh build-grub         # render only GRUB artifacts
#   ./build.sh build-nixos        # render NixOS adapter modules + kernels
#   ./build.sh build-debian       # render Debian adapter
#   ./build.sh build-nvram        # render NVRAM apply.sh
#
#   ./build.sh deploy-all         # build + install everything (refind, grub, nixos, debian, nvram)
#   ./build.sh deploy-refind      # build-refind + install-refind
#   ./build.sh deploy-grub        # build-grub  + install-grub
#   ./build.sh deploy-nixos       # build-nixos + install-nixos (drops modules into flake)
#   ./build.sh deploy-debian      # build-debian + install-debian (Phase 2 stub)
#   ./build.sh deploy-nvram       # build-nvram + run efibootmgr apply.sh
#
#   ./build.sh validate           # JSON schema + UUID sanity
#   ./build.sh plan               # diff dist/ vs live system
#   ./build.sh verify             # health-check live ESP / NVRAM / refind.conf
#   ./build.sh status             # dist/ freshness, snapshot count
#   ./build.sh snapshot           # capture /boot, NVRAM, blkid → snapshots/<date>/
#   ./build.sh help

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ENGINE="$SCRIPT_DIR/src/engine"

# shellcheck source=src/engine/lib/log.sh
. "$ENGINE/lib/log.sh"

# shellcheck source=src/engine/lib/json.sh
. "$ENGINE/lib/json.sh"

BOOT_JSON="$SCRIPT_DIR/src/boot.json"
SCHEMA="$SCRIPT_DIR/src/boot.schema.json"

# ═══════════════════════════════════════════════════════════════════════════
# BUILD — render src/ → dist/  (no system writes)
# ═══════════════════════════════════════════════════════════════════════════

build_refind() {
    sh "$ENGINE/render-refind-binary.sh"
    sh "$ENGINE/render-refind-conf.sh"
}

build_grub() {
    sh "$ENGINE/render-grub-cfg-preview.sh"
    sh "$ENGINE/render-grub-cfg.sh"
    sh "$ENGINE/render-grub-binaries.sh"
}

build_nixos() {
    sh "$ENGINE/render-nixos-modules.sh"
    sh "$ENGINE/render-nixos-kernels.sh"
}

build_debian() {
    sh "$ENGINE/render-debian.sh"
}

build_nvram() {
    sh "$ENGINE/render-nvram.sh"
}

build_all() {
    header "build-all — render every engine into dist/"
    build_nixos
    build_debian
    build_grub
    build_refind
    build_nvram
    write_manifest
    log "build-all: done"
}

write_manifest() {
    EFI_INSTALL_DIR=$(jq -r '.grub.install.efi_install_dir // "/EFI/bootloader"' "$BOOT_JSON")
    cat > "$SCRIPT_DIR/dist/MANIFEST.txt" <<EOF
# aa_bootloader dist/ manifest
# Generated $(date '+%Y-%m-%d %H:%M:%S')

## Adapters (per-OS, copied at install time)
adapters/nixos/             → aa_nixos-surface_host/src/modules/
adapters/debian/            → /etc/ (Phase 2 stub)

## Loaders (parallel: rEFInd primary + GRUB fallback)
boot/efi/EFI/refind/        → /boot/efi/EFI/refind/
boot/efi${EFI_INSTALL_DIR}/ → /boot/efi${EFI_INSTALL_DIR}/  (from boot.json .grub.install.efi_install_dir)
boot/grub/                  → /boot/grub/

## Firmware (UEFI)
nvram/apply.sh              → run via efibootmgr

## Previews (human-readable, not deployed)
previews/                   preview of menu structure from boot.json
EOF
    log "Wrote dist/MANIFEST.txt"
}

# ═══════════════════════════════════════════════════════════════════════════
# DEPLOY — build + install onto live system
# ═══════════════════════════════════════════════════════════════════════════

deploy_refind() {
    header "deploy-refind — build + install rEFInd"
    build_refind
    sh "$ENGINE/install-refind.sh"
}

deploy_grub() {
    header "deploy-grub — build + install GRUB (fallback loader)"
    build_grub
    sh "$ENGINE/install-grub.sh"
}

deploy_nixos() {
    header "deploy-nixos — build + drop modules into NixOS flake"
    build_nixos
    sh "$ENGINE/install-nixos.sh"
}

deploy_debian() {
    header "deploy-debian — build + install Debian adapter (Phase 2 stub)"
    build_debian
    sh "$ENGINE/install-debian.sh"
}

deploy_nvram() {
    header "deploy-nvram — build + apply efibootmgr entries"
    build_nvram
    sh "$SCRIPT_DIR/dist/nvram/apply.sh"
}

deploy_all() {
    header "deploy-all — build + install everything (rEFInd + GRUB in parallel)"
    build_all
    sh "$ENGINE/install-nixos.sh"
    sh "$ENGINE/install-debian.sh"
    sh "$ENGINE/install-grub.sh"
    sh "$ENGINE/install-refind.sh"
    sh "$SCRIPT_DIR/dist/nvram/apply.sh"
    log "deploy-all: done"
}

# ═══════════════════════════════════════════════════════════════════════════
# READ-ONLY COMMANDS
# ═══════════════════════════════════════════════════════════════════════════

cmd_validate() {
    header "validate — JSON + sanity"
    if [ ! -f "$BOOT_JSON" ]; then
        error "Missing: $BOOT_JSON"
        return 1
    fi
    if [ ! -f "$SCHEMA" ]; then
        error "Missing: $SCHEMA"
        return 1
    fi
    if command -v ajv >/dev/null 2>&1; then
        ajv validate -s "$SCHEMA" -d "$BOOT_JSON" --strict=false
    elif command -v check-jsonschema >/dev/null 2>&1; then
        check-jsonschema --schemafile "$SCHEMA" "$BOOT_JSON"
    else
        warn "No JSON schema validator (ajv / check-jsonschema) — skipping schema check"
        warn "Install with: nix-shell -p check-jsonschema"
    fi
    if ! jq empty "$BOOT_JSON" 2>/dev/null; then
        error "Invalid JSON syntax in $BOOT_JSON"
        return 1
    fi
    log "JSON parses cleanly"

    log "Cross-checking UUIDs against block devices..."
    for path in .uefi.esp.uuid .uefi.boot.uuid .initrd.luks.device_uuid; do
        uuid=$(jq -r "$path" "$BOOT_JSON")
        if [ "$uuid" != "null" ] && [ -n "$uuid" ]; then
            if blkid 2>/dev/null | grep -qF "$uuid"; then
                log "  $path=$uuid  ✓ found on disk"
            else
                warn "  $path=$uuid  ✗ NOT found on disk (multi-OS env? OK if not on this machine)"
            fi
        fi
    done
    # ── Rendered stanza-icon guard (regression test, 2026-06-11) ────────────
    # rEFInd resolves manual-stanza `icon` paths from the VOLUME ROOT
    # (refind/config.c: egLoadIcon(CurrentVolume->RootDir, ...)), unlike
    # icons_dir/banner which are rEFInd-dir-relative. Relative stanza paths
    # never resolve → silent fallback to generic icons ("first row broken,
    # tool row fine"). Guard: every rendered stanza icon must be absolute
    # AND exist in the dist ESP tree.
    DIST_REFIND_CONF="$SCRIPT_DIR/dist/boot/efi/EFI/refind/refind.conf"
    if [ -f "$DIST_REFIND_CONF" ]; then
        log "Checking rendered stanza icon paths (volume-root + existence)..."
        icon_fail=0
        for p in $(awk '$1=="icon" {print $2}' "$DIST_REFIND_CONF"); do
            case "$p" in
                /*)
                    if [ ! -f "$SCRIPT_DIR/dist/boot/efi$p" ]; then
                        error "  stanza icon missing in dist ESP tree: $p"
                        icon_fail=1
                    fi
                    ;;
                *)
                    error "  stanza icon not volume-root absolute: $p"
                    icon_fail=1
                    ;;
            esac
        done
        if [ "$icon_fail" -ne 0 ]; then
            error "stanza icon check FAILED — rEFInd would show fallback icons"
            return 1
        fi
        log "  stanza icons: all absolute + present in dist ✓"
    else
        warn "dist refind.conf not rendered yet — run generate first for the icon guard"
    fi

    log "validate: done"
}

cmd_plan() {
    header "plan — diff dist/ vs live system"
    log "(Phase 1: structural plan only)"
    log ""
    log "Adapter files dist/adapters/nixos/* → aa_nixos-surface_host/src/modules/"
    for f in "$SCRIPT_DIR/dist/adapters/nixos/"*.nix; do
        [ -f "$f" ] || continue
        bn=$(basename "$f")
        live="$SCRIPT_DIR/../aa_nixos-surface_host/src/modules/$bn"
        if [ -f "$live" ]; then
            if cmp -s "$f" "$live"; then
                log "  unchanged   $bn"
            else
                log "  WOULD COPY  $bn  (diff vs flake)"
            fi
        else
            log "  WOULD ADD   $bn  (not in flake)"
        fi
    done
    log "plan: done"
}

cmd_verify() {
    header "verify — health-check live ESP / NVRAM / refind.conf vs dist"
    sh "$ENGINE/verify-refind.sh"
}

cmd_verify_boot() {
    header "verify-boot — comprehensive pre-reboot soft-boot integrity audit"
    sh "$ENGINE/verify-boot-ready.sh"
}

cmd_status() {
    header "status — dist freshness + snapshots"
    if [ -d "$SCRIPT_DIR/dist" ]; then
        n_files=$(find "$SCRIPT_DIR/dist" -type f 2>/dev/null | wc -l)
        last=$(find "$SCRIPT_DIR/dist" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f1 || echo 0)
        last_human=$(date -d "@$last" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "(unknown)")
        log "dist/ files: $n_files (latest: $last_human)"
    else
        warn "dist/ does not exist — run: ./build.sh build-all"
    fi
    if [ -d "$SCRIPT_DIR/snapshots" ]; then
        n_snaps=$(find "$SCRIPT_DIR/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        log "snapshots: $n_snaps"
    fi
}

cmd_test() {
    sh "$ENGINE/test-build.sh"
}

cmd_clean() {
    header "clean — remove dist/ and snapshots/.result"
    if [ -d "$SCRIPT_DIR/dist" ]; then
        n_files=$(find "$SCRIPT_DIR/dist" -type f 2>/dev/null | wc -l)
        rm -rf "$SCRIPT_DIR/dist"
        log "Removed dist/ ($n_files files)"
    else
        log "dist/ already absent"
    fi
    [ -e "$SCRIPT_DIR/.result" ] && { rm -rf "$SCRIPT_DIR/.result"; log "Removed .result"; }
    log "clean: done — next build re-renders from src/ + boot.json"
}

cmd_snapshot() {
    header "snapshot — capture live state"
    out="$SCRIPT_DIR/snapshots/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$out"
    if command -v efibootmgr >/dev/null 2>&1; then
        sudo efibootmgr -v > "$out/nvram.txt" 2>&1 || warn "efibootmgr capture failed"
    fi
    if command -v blkid >/dev/null 2>&1; then
        sudo blkid > "$out/blkid.txt" 2>&1 || warn "blkid capture failed"
    fi
    if [ -d /boot ]; then
        ls -laR /boot > "$out/boot-listing.txt" 2>&1 || true
    fi
    if [ -f /boot/grub/grubenv ]; then
        cp /boot/grub/grubenv "$out/grubenv"
    fi
    log "Snapshot: $out"
}

cmd_help() {
    cat <<'EOF'
aa_bootloader/build.sh — boot SoT orchestrator

USAGE:
  ./build.sh <command>

BUILD (render src/ → dist/, no system writes):
  build-all         every engine
  build-refind      rEFInd binary + refind.conf
  build-grub        GRUB cfg + binaries (fallback loader)
  build-nixos       NixOS adapter modules + kernel staging
  build-debian      Debian adapter (Phase 2 stub)
  build-nvram       UEFI NVRAM apply.sh

DEPLOY (build + install onto live system):
  deploy-all        rEFInd + GRUB (parallel) + adapters + NVRAM
  deploy-refind     rEFInd only (ESP)
  deploy-grub       GRUB only (ESP, fallback)
  deploy-nixos      NixOS modules → host flake
  deploy-debian     Debian adapter → /etc (Phase 2)
  deploy-nvram      apply efibootmgr entries

READ-ONLY:
  validate          JSON schema + UUID sanity
  test              run dist/ tests (FIRE RULE 5: no task done without a tester)
  verify-boot       comprehensive pre-reboot integrity audit (T-A..T-I)
  plan              diff dist/ vs live
  verify            health-check live ESP / NVRAM / refind.conf
  status            dist freshness, snapshot count
  snapshot          capture /boot + NVRAM + blkid → snapshots/
  clean             remove dist/ and .result (drops stale install dirs)
  help              this message

FLAGS (accepted anywhere on the command line):
  --dry-run         install scripts exit before any write
                    (env: DRY_RUN=1 — same effect)
                    (json: .engine.dry_run=true — session-wide)

ARCHITECTURE:
  One engine (this build.sh + src/engine/*.sh).
  One SoT (src/boot.json).
  rEFInd default + GRUB fallback — built in parallel, both end up on ESP.

EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# DISPATCH
# ═══════════════════════════════════════════════════════════════════════════

[ $# -eq 0 ] && { cmd_help; exit 0; }

# Parse global --dry-run flag (accepted anywhere on the command line).
# Sets DRY_RUN=1 so every install-*.sh that's invoked downstream bails
# before any write — install scripts already honor this env var (and
# fall back to .engine.dry_run in boot.json if unset).
NEW_ARGC=0
for arg in "$@"; do
    if [ "$arg" = "--dry-run" ]; then
        DRY_RUN=1
        export DRY_RUN
    else
        NEW_ARGC=$((NEW_ARGC + 1))
        eval "NEW_ARG_${NEW_ARGC}=\"\$arg\""
    fi
done
set -- ""
i=0
while [ $i -lt $NEW_ARGC ]; do
    i=$((i + 1))
    eval "set -- \"\$@\" \"\$NEW_ARG_${i}\""
done
shift  # drop the leading "" we used to seed
[ "${DRY_RUN:-0}" = "1" ] && warn "--dry-run active: install scripts will exit before any write"

cmd="$1"; shift || true

case "$cmd" in
    build-all)      build_all "$@" ;;
    build-refind)   build_refind "$@" ;;
    build-grub)     build_grub "$@" ;;
    build-nixos)    build_nixos "$@" ;;
    build-debian)   build_debian "$@" ;;
    build-nvram)    build_nvram "$@" ;;
    deploy-all)     deploy_all "$@" ;;
    deploy-refind)  deploy_refind "$@" ;;
    deploy-grub)    deploy_grub "$@" ;;
    deploy-nixos)   deploy_nixos "$@" ;;
    deploy-debian)  deploy_debian "$@" ;;
    deploy-nvram)   deploy_nvram "$@" ;;
    validate)       cmd_validate "$@" ;;
    plan)           cmd_plan "$@" ;;
    test)           cmd_test "$@" ;;
    verify-boot)    cmd_verify_boot "$@" ;;
    clean)          cmd_clean "$@" ;;
    verify)         cmd_verify "$@" ;;
    status)         cmd_status "$@" ;;
    snapshot)       cmd_snapshot "$@" ;;
    help|-h|--help) cmd_help ;;
    # Back-compat for old verbs (will print a deprecation note then dispatch)
    generate)       warn "command 'generate' renamed → 'build-all'"; build_all ;;
    deploy)         error "command 'deploy --target X' replaced by 'deploy-X'"; cmd_help; exit 1 ;;
    test)           warn "command 'test' renamed → 'verify'"; cmd_verify ;;
    *) error "Unknown command: $cmd"; cmd_help; exit 1 ;;
esac
