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
    log_err "local ISO builds are disabled — the ISO is built on GitHub Actions only.
  Trigger:  gh workflow run ship-my-konsole-iso.yml --repo diegonmarcos/cloud-unix
  Watch:    gh run watch \$(gh run list -w ship-my-konsole-iso.yml -L1 --json databaseId -q '.[0].databaseId')
  Consume:  ./build.sh install-partition   (downloads the my-konsole-iso-latest release)"
}

build_vm() {
    log_err "local VM builds are disabled — see build_iso; GHA is the only builder."
}

build_raw() {
    log_err "local raw-image builds are disabled — see build_iso; GHA is the only builder."
}

# Extract kernel/initrd/cmdline from the ISO tree's own GRUB config on $1 and
# write them into aa_bootloader's boot.json (grub.menu.mykonsole), which rEFInd
# renders from. Keeps the volatile nix-store hashes data-driven.
sync_boot_json() {
    local dev="$1" label="$2"
    local bj="$SCRIPT_DIR/../../aa_bootloader/src/boot.json"
    [ -f "$bj" ] || { log_info "aa_bootloader boot.json not found — skipping SoT sync"; return 0; }

    local md; md=$(mktemp -d)
    mount -o ro "$dev" "$md" || log_err "SoT sync: remount of $dev failed"
    # First `linux ...` line = the ISO's default menuentry. Collapse the ISO's
    # /boot//nix double slash, drop its ${isoboot} placeholder (set only when
    # booting an .iso file via findiso) and the root= it hardcodes — boot.json
    # carries root separately as root_param.
    local lin ini kern opts
    lin=$(command grep -m1 -E '^[[:space:]]*linux[[:space:]]+' "$md/EFI/BOOT/grub.cfg" | sed 's|/boot//|/boot/|')
    ini=$(command grep -m1 -E '^[[:space:]]*initrd[[:space:]]+' "$md/EFI/BOOT/grub.cfg" | sed 's|/boot//|/boot/|' | awk '{print $2}')
    umount "$md"; rmdir "$md"
    kern=$(printf '%s' "$lin" | awk '{print $2}')
    opts=$(printf '%s' "$lin" | cut -d' ' -f3- | sed -e 's|\${isoboot}||' -e 's|root=[^ ]*||' -e 's|  *| |g' -e 's|^ ||' -e 's| $||')
    [ -n "$kern" ] && [ -n "$ini" ] && [ -n "$opts" ] \
        || log_err "SoT sync: could not parse kernel/initrd/options out of $dev:/EFI/BOOT/grub.cfg"

    local tmp; tmp=$(mktemp)
    jq --arg k "$kern" --arg i "$ini" --arg o "$opts" --arg l "LABEL=$label" \
       '.grub.menu.mykonsole.kernel = $k
        | .grub.menu.mykonsole.initrd = $i
        | .grub.menu.mykonsole.options = $o
        | .grub.menu.mykonsole.root_param = $l' "$bj" > "$tmp" \
        || log_err "SoT sync: jq update of boot.json failed"
    mv "$tmp" "$bj"
    log_ok "SoT sync: boot.json grub.menu.mykonsole ← $(basename "$(dirname "$kern")")"

    # Tester: what we just wrote must actually exist on the partition.
    local vd; vd=$(mktemp -d)
    mount -o ro "$dev" "$vd" || log_err "SoT sync VERIFY: remount failed"
    if [ -f "$vd$kern" ] && [ -f "$vd$ini" ]; then
        log_ok "SoT sync VERIFY: kernel + initrd present at the recorded paths"
    else
        umount "$vd"; rmdir "$vd"
        log_err "SoT sync VERIFY: $kern or $ini missing on $dev"
    fi
    umount "$vd"; rmdir "$vd"
}

install_partition() {
    log_head "Installing my-konsole live tree onto rescue partition (rEFInd boots it natively)"

    local J="$SCRIPT_DIR/install.json"
    command -v jq >/dev/null || log_err "jq required"
    local DEV UUID LABEL EFI REL MAN REPO
    DEV=$(jq -r '.partition.device'         "$J")
    UUID=$(jq -r '.partition.uuid'          "$J")
    LABEL=$(jq -r '.partition.volume_label' "$J")
    EFI=$(jq -r '.partition.efi_binary'     "$J")
    REL=$(jq -r '.partition.iso_release'    "$J")
    MAN=$(jq -r '.partition.iso_manifest'   "$J")
    REPO=$(jq -r '.partition.iso_repo'      "$J")

    # ── Resolve ISO from the rolling GHA RELEASE — never a local build ────────
    # (ship-my-konsole-iso publishes the ISO as release $REL: split .part files
    # under GH's 2 GiB asset cap + a sha256 manifest. The manifest is the SoT:
    # a local my-konsole.iso is reused ONLY if it matches the released hash,
    # otherwise the parts are fetched and reassembled.)
    local ISO="$SCRIPT_DIR/my-konsole.iso"
    command -v gh >/dev/null || log_err "gh required to fetch the ISO release"
    gh release download "$REL" --repo "$REPO" -p "$MAN" -D "$SCRIPT_DIR" --clobber \
        || log_err "no '$REL' release found on $REPO — run ship-my-konsole-iso on GHA first"
    if [ -f "$ISO" ] && (cd "$SCRIPT_DIR" && command grep " my-konsole.iso\$" "$MAN" | sha256sum -c --quiet - 2>/dev/null); then
        log_ok "local my-konsole.iso matches release manifest — reusing"
    else
        rm -f "$ISO" "$SCRIPT_DIR"/my-konsole.iso.part*
        # gh release download is all-or-nothing per asset (no resume): on a
        # flaky/metered link a multi-GB transfer rarely lands first try, so
        # retry the whole fetch a few times. Parts are <2 GiB each — better
        # odds per attempt than the old single 2.4 GiB artifact.
        local n=0 tries=8
        until (cd "$SCRIPT_DIR" && command grep ' my-konsole\.iso\.part' "$MAN" | sha256sum -c --quiet - 2>/dev/null); do
            n=$((n+1))
            [ "$n" -gt "$tries" ] && log_err "gh release download failed after $tries attempts ($REL on $REPO) — network too unstable"
            log_info "download attempt $n/$tries…"
            gh release download "$REL" --repo "$REPO" -p 'my-konsole.iso.part*' -D "$SCRIPT_DIR" --clobber \
                || { log_info "attempt $n stalled; retrying in 8s…"; sleep 8; }
        done
        cat "$SCRIPT_DIR"/my-konsole.iso.part?? > "$ISO" || log_err "reassembly of ISO parts failed"
        (cd "$SCRIPT_DIR" && command grep " my-konsole.iso\$" "$MAN" | sha256sum -c --quiet -) \
            || log_err "reassembled ISO fails sha256 from $MAN — corrupt download"
        rm -f "$SCRIPT_DIR"/my-konsole.iso.part*
    fi
    log_ok "ISO: $ISO (sha256-verified against $REL/$MAN)"

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

    # ── Push the ISO's boot params into aa_bootloader's SoT ───────────────────
    # rEFInd boots p8 NATIVELY (its ext4_x64 driver reads p8) instead of
    # chainloading the ISO's own GRUB — that GRUB has no ext2 module and cannot
    # read the very partition it now lives on (proven 2026-08-19; see boot.json
    # grub.menu.mykonsole._refind_native_note). So rEFInd needs the kernel,
    # initrd and cmdline, all of which carry nix-store hashes that change on
    # every ISO rebuild. Re-extract them from the ISO's own default menuentry so
    # they can never go stale by hand.
    sync_boot_json "$DEV" "$LABEL"

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
