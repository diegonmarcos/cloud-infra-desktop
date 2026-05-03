#!/bin/sh
# aa_bootloader/build.sh — orchestrator for the boot SoT
# POSIX. Run from any OS that mounts the LUKS pool.
#
# Usage:
#   ./build.sh generate                  # render src/ → dist/
#   ./build.sh validate                  # JSON schema + sanity checks
#   ./build.sh plan                      # diff dist/ vs live system
#   ./build.sh deploy --target nixos     # copy dist/adapters/nixos/* into the flake
#   ./build.sh deploy --target debian    # (Phase 2 stub)
#   ./build.sh deploy --target grub      # (Phase 3 stub) write /boot/grub/grub.cfg
#   ./build.sh status                    # show dist/ freshness, last deploy times
#   ./build.sh snapshot                  # capture live system state into snapshots/
#   ./build.sh help

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=gen/lib/log.sh
. "$SCRIPT_DIR/src/gen/lib/log.sh"

# shellcheck source=gen/lib/json.sh
. "$SCRIPT_DIR/src/gen/lib/json.sh"

BOOT_JSON="$SCRIPT_DIR/src/boot.json"
SCHEMA="$SCRIPT_DIR/src/boot.schema.json"

# ═══════════════════════════════════════════════════════════════════════════
# SUBCOMMANDS
# ═══════════════════════════════════════════════════════════════════════════

cmd_generate() {
    header "generate — src/ → dist/"
    sh "$SCRIPT_DIR/src/gen/render-nixos-adapter.sh"
    sh "$SCRIPT_DIR/src/gen/render-grub-cfg-preview.sh"
    sh "$SCRIPT_DIR/src/gen/render-grub-cfg.sh"
    sh "$SCRIPT_DIR/src/gen/render-grub-binaries.sh"
    sh "$SCRIPT_DIR/src/gen/render-kernels.sh"
    sh "$SCRIPT_DIR/src/gen/render-debian-adapter.sh"
    sh "$SCRIPT_DIR/src/gen/render-nvram.sh"

    # Write a MANIFEST that summarizes dist/ contents
    cat > "$SCRIPT_DIR/dist/MANIFEST.txt" <<EOF
# aa_bootloader dist/ manifest
# Generated $(date '+%Y-%m-%d %H:%M:%S')

## Adapters (per-OS, copied at deploy time)
adapters/nixos/             → aa_nixos-surface_host/src/modules/
adapters/debian/            → /etc/ (Phase 2)

## Universal artifacts (Phase 3)
boot/grub/grub.cfg          → /boot/grub/grub.cfg (Phase 3)
boot/efi/EFI/...            → /boot/efi/EFI/...  (Phase 3)
nvram/apply.sh              → run via efibootmgr (Phase 3)

## Previews (human-readable, not deployed)
previews/grub-menu.txt      preview of GRUB menu structure from boot.json
EOF
    log "Wrote dist/MANIFEST.txt"
    log "generate: done"
}

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
    validate_json "$BOOT_JSON" "$SCHEMA"
    log "JSON parses cleanly"

    # Cross-check UUIDs against actual disks (informational)
    log "Cross-checking UUIDs against block devices..."
    for key in '.uefi.esp.uuid' '.uefi.boot.uuid' '.initrd.luks.device_uuid'; do
        uuid="$(jq_get "$key")"
        # Just check if the UUID appears anywhere in blkid (lightweight)
        if blkid 2>/dev/null | grep -qi "$uuid"; then
            log "  $key=$uuid  ✓ found on disk"
        else
            warn "  $key=$uuid  not found on disk"
        fi
    done
    log "validate: done"
}

cmd_plan() {
    header "plan — dist/ vs live"
    cmd_generate >/dev/null 2>&1 || true

    DIFF_OUT="$SCRIPT_DIR/dist/previews/plan-vs-live.txt"
    {
        echo "# Plan: aa_bootloader/dist vs live system"
        echo "# $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        # NixOS adapter files
        echo "## adapters/nixos/ (Phase 1: NixOS flake state)"
        FLAKE_MODULES="${FLAKE_MODULES_DIR:-$SCRIPT_DIR/../aa_nixos-surface_host/src/modules}"
        for f in boot.json hardware_bootloader_grub.nix hardware_bootloader_boot.nix swap_hibernate.nix; do
            src="$SCRIPT_DIR/dist/adapters/nixos/$f"
            dst="$FLAKE_MODULES/$f"
            if [ ! -f "$src" ]; then
                echo "  $f: dist MISSING"
            elif [ ! -e "$dst" ]; then
                echo "  $f: would CREATE in flake"
            elif cmp -s "$src" "$dst"; then
                echo "  $f: unchanged"
            else
                echo "  $f: DIFFERS — diff:"
                diff -u "$dst" "$src" | sed 's/^/    /' | head -40
            fi
        done

        echo ""
        echo "## boot.json UUID sanity"
        for key in '.uefi.esp.uuid' '.uefi.boot.uuid' '.initrd.luks.device_uuid'; do
            uuid="$(jq_get "$key")"
            if blkid 2>/dev/null | grep -qi "$uuid"; then
                echo "  $key=$uuid  ✓"
            else
                echo "  $key=$uuid  ✗ not on disk"
            fi
        done

        echo ""
        echo "## NVRAM (Phase 3 will manage)"
        if command -v efibootmgr >/dev/null 2>&1; then
            efibootmgr 2>/dev/null | head -20
        else
            echo "  efibootmgr not installed"
        fi
    } > "$DIFF_OUT"

    log "Wrote: $DIFF_OUT"
    cat "$DIFF_OUT"
}

cmd_deploy() {
    target=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --target) target="$2"; shift 2 ;;
            *) error "Unknown deploy flag: $1"; return 1 ;;
        esac
    done
    [ -z "$target" ] && { error "deploy requires --target <nixos|debian|grub>"; return 1; }

    cmd_generate
    case "$target" in
        nixos)  sh "$SCRIPT_DIR/src/gen/deploy-nixos.sh" ;;
        debian) sh "$SCRIPT_DIR/src/gen/deploy-debian.sh" ;;
        grub)   sh "$SCRIPT_DIR/src/gen/deploy-grub.sh" ;;
        *) error "Unknown target: $target"; return 1 ;;
    esac
}

cmd_status() {
    header "status"
    if [ -d "$SCRIPT_DIR/dist" ]; then
        log "dist/ last generated: $(stat -c %y "$SCRIPT_DIR/dist/MANIFEST.txt" 2>/dev/null || echo 'unknown')"
    else
        warn "dist/ not generated yet — run: ./build.sh generate"
    fi
    log "src/boot.json last edited: $(stat -c %y "$BOOT_JSON")"
    if [ -d "$SCRIPT_DIR/snapshots" ]; then
        log "snapshots: $(ls -1 "$SCRIPT_DIR/snapshots" 2>/dev/null | wc -l) entries"
    fi
}

cmd_snapshot() {
    header "snapshot — capture live state"
    ts="$(date '+%Y%m%d-%H%M%S')"
    out="$SCRIPT_DIR/snapshots/$ts"
    mkdir -p "$out"

    # Capture relevant live state
    cp /boot/grub/grub.cfg "$out/grub.cfg" 2>/dev/null || warn "no /boot/grub/grub.cfg"
    efibootmgr -v > "$out/efibootmgr.txt" 2>&1 || true
    blkid > "$out/blkid.txt" 2>&1 || true
    lsblk -f > "$out/lsblk.txt" 2>&1 || true
    cat /proc/cmdline > "$out/proc-cmdline.txt" 2>&1 || true
    if [ -f /boot/grub/grubenv ]; then
        cp /boot/grub/grubenv "$out/grubenv"
    fi

    log "Snapshot: $out"
}

cmd_help() {
    cat <<'EOF'
aa_bootloader/build.sh — boot SoT orchestrator

USAGE:
  ./build.sh <command> [args]

COMMANDS:
  generate            Render src/ → dist/ (no system writes)
  validate            JSON schema + UUID sanity
  plan                Diff dist/ vs live system + flake state
  deploy --target X   Copy dist/ artifacts into target system
                      X = nixos | debian | grub
  status              dist/ freshness, snapshot count
  snapshot            Capture current /boot, NVRAM, blkid → snapshots/<date>/
  help                Show this help

ENVIRONMENT:
  YES=1                    Skip interactive confirmations
  REBUILD_ACTION=boot      For --target nixos: also run nixos-rebuild
                           values: none (default), boot, switch, test, dry-build
  FLAKE_MODULES_DIR=/path  Override location of NixOS flake modules

EXAMPLES:
  ./build.sh validate
  ./build.sh generate
  ./build.sh plan
  YES=1 REBUILD_ACTION=dry-build ./build.sh deploy --target nixos
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# DISPATCH
# ═══════════════════════════════════════════════════════════════════════════

[ $# -eq 0 ] && { cmd_help; exit 0; }

cmd="$1"; shift || true

case "$cmd" in
    generate) cmd_generate "$@" ;;
    validate) cmd_validate "$@" ;;
    plan)     cmd_plan "$@" ;;
    deploy)   cmd_deploy "$@" ;;
    status)   cmd_status "$@" ;;
    snapshot) cmd_snapshot "$@" ;;
    help|-h|--help) cmd_help ;;
    *) error "Unknown command: $cmd"; cmd_help; exit 1 ;;
esac
