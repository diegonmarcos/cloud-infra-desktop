#!/bin/bash
# Build my-konsole ISO
#
# Usage:
#   ./build.sh         - Build ISO
#   ./build.sh vm      - Build and run VM for testing
#   ./build.sh raw     - Build raw disk image
#   ./build.sh clean   - Clean build artifacts

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_ok()   { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
log_info() { printf "${YELLOW}[INFO]${NC} %s\n" "$1"; }
log_head() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
log_err()  { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }

build_iso() {
    log_head "Building my-konsole ISO"

    # Check nix is available
    if ! command -v nix &>/dev/null; then
        log_err "Nix is not installed. Install with: curl -L https://nixos.org/nix/install | sh"
    fi

    log_info "Building ISO (this may take 10-30 minutes on first build)..."

    nix build .#iso \
        --extra-experimental-features "nix-command flakes" \
        --out-link result

    if [ -L result ]; then
        ISO_PATH=$(readlink -f result)/iso/*.iso
        ISO_SIZE=$(du -h $ISO_PATH | cut -f1)
        log_ok "ISO built: $ISO_PATH"
        log_ok "Size: $ISO_SIZE"

        # Copy to current directory
        cp $ISO_PATH ./my-konsole.iso
        log_ok "Copied to: ./my-konsole.iso"

        echo ""
        echo "To use with Ventoy:"
        echo "  cp my-konsole.iso /path/to/ventoy/usb/"
    else
        log_err "Build failed - no result link created"
    fi
}

build_vm() {
    log_head "Building NixOS Surface VM for testing"

    nix build .#vm \
        --extra-experimental-features "nix-command flakes" \
        --out-link result-vm

    log_ok "VM built. Run with:"
    echo "  ./result-vm/bin/run-*-vm"
}

build_raw() {
    log_head "Building Raw Disk Image"

    nix build .#raw \
        --extra-experimental-features "nix-command flakes" \
        --out-link result-raw

    log_ok "Raw image built: $(readlink -f result-raw)"
}

install_partition() {
    log_head "Installing my-konsole live tree onto rescue partition (approach A: chainload)"

    local J="$SCRIPT_DIR/install.json"
    command -v jq >/dev/null || log_err "jq required"
    local DEV UUID LABEL EFI ART WF REPO
    DEV=$(jq -r '.partition.device'         "$J")
    UUID=$(jq -r '.partition.uuid'          "$J")
    LABEL=$(jq -r '.partition.volume_label' "$J")
    EFI=$(jq -r '.partition.efi_binary'     "$J")
    ART=$(jq -r '.partition.iso_artifact'   "$J")
    WF=$(jq -r '.partition.iso_workflow'    "$J")
    REPO=$(jq -r '.partition.iso_repo'      "$J")

    # ── Resolve ISO: prefer local build, else pull the GHA workflow ARTIFACT ──
    # (ship-my-konsole-iso publishes the .iso via actions/upload-artifact, NOT a
    # GH release — so fetch it from the latest successful run with `gh run download`.)
    local ISO="$SCRIPT_DIR/my-konsole.iso"
    if [ ! -f "$ISO" ]; then
        log_info "No local ISO — fetching artifact '$ART' from latest successful $WF run…"
        command -v gh >/dev/null || log_err "gh required to fetch the ISO (or run ./build.sh first)"
        local RID
        RID=$(gh run list --repo "$REPO" --workflow "$WF" --status success \
                --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)
        [ -n "$RID" ] || log_err "no successful $WF run yet — build the ISO on GHA first"
        # gh run download is all-or-nothing (no resume): a single mid-transfer
        # stall throws away all progress. On a flaky/metered link (hotspot, NAT64)
        # a multi-GB artifact rarely lands first try, so retry the whole fetch a
        # few times before giving up. Each attempt starts clean (gh leaves no
        # partial), so this only needs one good window to succeed.
        local n=0 tries=8
        until ISO=$(command find "$SCRIPT_DIR" -maxdepth 2 -name '*.iso' | command head -1); [ -f "$ISO" ]; do
            n=$((n+1))
            [ "$n" -gt "$tries" ] && log_err "gh run download failed after $tries attempts (run $RID, artifact $ART) — network too unstable for the $(printf '%s' "$ART") transfer"
            log_info "download attempt $n/$tries…"
            gh run download "$RID" --repo "$REPO" -n "$ART" -D "$SCRIPT_DIR" || { log_info "attempt $n stalled; retrying in 8s…"; sleep 8; }
        done
    fi
    log_ok "ISO: $ISO"

    # ── Safety: the device MUST be the exact UUID from install.json ───────────
    local actual
    actual=$(blkid -s UUID -o value "$DEV" 2>/dev/null || true)
    [ "$actual" = "$UUID" ] || log_err "SAFETY ABORT: $DEV UUID is '$actual', expected '$UUID' (install.json). Refusing to write."
    findmnt -rn "$DEV" >/dev/null 2>&1 && log_err "SAFETY ABORT: $DEV is mounted — unmount it first."

    # ── Reformat with a rEFInd-readable ext4 feature set (data-driven) ────────
    # rEFInd's read-only ext4_x64.efi driver refuses to mount a filesystem with
    # an INCOMPAT bit it doesn't know (e.g. metadata_csum_seed) → 'Invalid Loader
    # File' when chainloading p8. Modern mke2fs enables those by default, so we
    # own the mkfs here with the incompatible features disabled (see
    # install.json partition.mkfs._reason). rsync --delete below repopulates the
    # whole tree, so this loses nothing. -U preserves the pinned UUID (safety
    # guard + GRUB efi_uuid); PARTUUID lives in the GPT and is untouched.
    if [ "$(jq -r '.partition.mkfs.enabled // false' "$J")" = "true" ]; then
        local FS OFF
        FS=$(jq -r '.partition.mkfs.type' "$J")
        # comma-joined "^feat" list from disable_features[]
        OFF=$(jq -r '[.partition.mkfs.disable_features[] | "^" + .] | join(",")' "$J")
        log_info "Reformatting $DEV as $FS (UUID kept $UUID; features off: $OFF)…"
        "mkfs.$FS" -F -U "$UUID" -L "$LABEL" -O "$OFF" "$DEV" \
            || log_err "mkfs.$FS on $DEV failed"
    fi

    # ── Mount ISO (ro loop) + target, verify payload BEFORE touching p8 ───────
    local isod pd
    isod=$(mktemp -d); pd=$(mktemp -d)
    trap 'umount "$isod" 2>/dev/null; umount "$pd" 2>/dev/null; rmdir "$isod" "$pd" 2>/dev/null' EXIT
    mount -o loop,ro "$ISO" "$isod" || log_err "loop-mount of ISO failed"
    [ -f "$isod$EFI" ]                 || log_err "ISO missing $EFI — wrong ISO?"
    [ -f "$isod/nix-store.squashfs" ]  || log_err "ISO missing /nix-store.squashfs — wrong ISO?"

    mount "$DEV" "$pd" || log_err "mount of $DEV failed"
    log_info "Syncing ISO tree → $DEV (rsync --delete)…"
    rsync -aHAX --delete "$isod"/ "$pd"/ || log_err "rsync failed"
    # No explicit `sync`: umount below already flushes all pending writes before
    # returning, so it was redundant — and on this host `sync` is shadowed by a
    # user wrapper (~/.nix-profile/bin/sync) that aborts under root. umount is the
    # durability barrier.
    umount "$pd" && umount "$isod"; trap - EXIT; rmdir "$isod" "$pd" 2>/dev/null || true

    # ── Relabel so the ISO's baked GRUB finds the squashfs by isoImage.volumeID
    e2label "$DEV" "$LABEL" || log_err "e2label failed"

    # ── Tester (FIRE RULE 5) ──────────────────────────────────────────────────
    local got; got=$(e2label "$DEV")
    [ "$got" = "$LABEL" ] || log_err "VERIFY: label is '$got', expected '$LABEL'"
    local vd; vd=$(mktemp -d)
    mount -o ro "$DEV" "$vd" || log_err "VERIFY: remount failed"
    if [ -f "$vd$EFI" ] && [ -f "$vd/nix-store.squashfs" ]; then
        log_ok "VERIFY: $EFI + nix-store.squashfs present on $DEV (label=$LABEL)"
    else
        umount "$vd"; rmdir "$vd"; log_err "VERIFY: payload missing on $DEV after sync"
    fi
    umount "$vd"; rmdir "$vd"

    # ── Tester: the fs must NOT carry features rEFInd's ext4 driver rejects ────
    if [ "$(jq -r '.partition.mkfs.enabled // false' "$J")" = "true" ]; then
        local feats bad
        feats=$(dumpe2fs -h "$DEV" 2>/dev/null | sed -n 's/^Filesystem features:[[:space:]]*//p')
        for bad in $(jq -r '.partition.mkfs.disable_features[]' "$J"); do
            case " $feats " in
                *" $bad "*) log_err "VERIFY: $DEV still has ext4 feature '$bad' — rEFInd will refuse to mount it";;
            esac
        done
        log_ok "VERIFY: no rEFInd-incompatible ext4 features on $DEV (mountable by ext4_x64.efi)"
    fi

    log_ok "p8 populated. Now wire boot menus:  cd ~/git/cloud-unix/aa_bootloader && ./build.sh deploy-refind deploy-grub"
}

clean() {
    log_head "Cleaning build artifacts"
    rm -f result result-vm result-raw
    rm -f *.iso
    log_ok "Cleaned"
}

check_flake() {
    log_head "Checking flake syntax"
    nix flake check \
        --extra-experimental-features "nix-command flakes" \
        --no-build
    log_ok "Flake syntax OK"
}

show_info() {
    echo ""
    echo "my-konsole - Ultra-Minimal USB Recovery"
    echo "================================================"
    echo ""
    echo "Features:"
    echo "  - Surface Pro hardware (linux-surface kernel via nixos-hardware)"
    echo "  - Openbox GUI (startx, no display manager)"
    echo "  - Fish shell + CLI tools (btop, ripgrep, fzf)"
    echo "  - Node.js + Claude Code (npx wrapper)"
    echo "  - WiFi GUI (nm-connection-editor)"
    echo "  - LUKS/btrfs recovery tools"
    echo ""
    echo "Credentials:"
    echo "  User: diego / root"
    echo "  Password: 1234567890"
    echo ""
    echo "After boot:"
    echo "  1. Auto-login to console as diego"
    echo "  2. Run 'startx' for Openbox GUI"
    echo "  3. Right-click for menu"
    echo ""
    echo "Build commands:"
    echo "  ./build.sh       - Build ISO"
    echo "  ./build.sh vm    - Build VM for testing"
    echo "  ./build.sh check - Check flake syntax"
    echo "  ./build.sh clean - Clean artifacts"
    echo ""
}

case "${1:-}" in
    vm)     build_vm ;;
    raw)    build_raw ;;
    clean)  clean ;;
    install-partition) install_partition ;;
    check)  check_flake ;;
    info)   show_info ;;
    ""|iso) build_iso ;;
    *)
        echo "Usage: $0 [iso|vm|raw|install-partition|check|clean|info]"
        exit 1
        ;;
esac
