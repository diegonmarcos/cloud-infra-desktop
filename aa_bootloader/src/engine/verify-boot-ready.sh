#!/bin/sh
# verify-boot-ready.sh — pre-reboot soft-boot integrity check.
#
# For every entry that will appear in the boot menu, verify that the
# bytes it eventually loads actually exist and are valid. No reboot, no
# QEMU, no kexec — just declarative checks against the live filesystem.
#
# Coverage:
#   T-A  ESP layout (/boot/efi/EFI/) has refind/, bootloader/, Microsoft/
#   T-B  rEFInd binary + drivers + theme assets present
#   T-C  every loader= path in refind.conf resolves on its volume
#   T-D  every kernel/initrd referenced exists, has correct magic bytes
#   T-E  GRUB EFI binary on ESP, valid PE32+
#   T-F  GRUB modules + font present on /boot
#   T-G  grub.cfg has menuentries for every distro in grub.linux_order
#   T-H  for each Linux partition: mount RO, verify /vmlinuz + /initrd.img
#         resolve to existing files, /etc/fstab is sane (referenced
#         filesystems are real), kernel file has Linux kernel magic
#   T-I  NVRAM has all declared entries with paths matching ESP layout
#
# This is the gate to flip before any reboot after a bootloader change.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
. "$ROOT_DIR/src/engine/lib/log.sh"

BOOT_JSON="$ROOT_DIR/src/boot.json"
ESP_UUID=$(jq -r '.uefi.esp.uuid' "$BOOT_JSON")
BOOT_UUID=$(jq -r '.uefi.boot.uuid' "$BOOT_JSON")

# Resolve actual mount points by UUID (don't hardcode /boot, /boot/efi).
ESP_DIR=$(findmnt -n -o TARGET --source UUID="$ESP_UUID" 2>/dev/null)
BOOT_DIR=$(findmnt -n -o TARGET --source UUID="$BOOT_UUID" 2>/dev/null)

PASS=0; FAIL=0; WARN=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
note() { echo "  ! $1"; WARN=$((WARN+1)); }
hdr()  { echo; echo "── $1 ──"; }

# ── Pre-flight ─────────────────────────────────────────────────────────────
[ -n "$ESP_DIR"  ] || { error "ESP UUID $ESP_UUID not mounted"; exit 2; }
[ -n "$BOOT_DIR" ] || { error "boot UUID $BOOT_UUID not mounted"; exit 2; }
log "ESP: $ESP_DIR (UUID=$ESP_UUID)"
log "/boot: $BOOT_DIR (UUID=$BOOT_UUID)"

# ── T-A: ESP top-level layout ──────────────────────────────────────────────
hdr "T-A ESP /EFI/ layout"
for d in refind bootloader Microsoft Boot; do
    if sudo -n test -d "$ESP_DIR/EFI/$d"; then
        ok "EFI/$d/ exists"
    else
        if [ "$d" = "Microsoft" ] || [ "$d" = "Boot" ]; then
            note "EFI/$d/ missing (firmware-managed; reappears on reboot)"
        else
            bad "EFI/$d/ MISSING"
        fi
    fi
done
sudo -n test -d "$ESP_DIR/EFI/NixOS-boot-efi" \
    && note "EFI/NixOS-boot-efi/ still on ESP (legacy, can be removed)" \
    || ok "EFI/NixOS-boot-efi/ purged"

# ── T-B: rEFInd binary + drivers + theme ──────────────────────────────────
hdr "T-B rEFInd files"
REFIND="$ESP_DIR/EFI/refind"
sudo -n test -f "$REFIND/refind_x64.efi" && \
    sudo -n file "$REFIND/refind_x64.efi" 2>&1 | grep -q "PE32+ executable" \
    && ok "refind_x64.efi present + valid PE32+" \
    || bad "refind_x64.efi missing or invalid"
sudo -n test -f "$REFIND/refind.conf" && ok "refind.conf present" || bad "refind.conf missing"
for drv in btrfs_x64 ext4_x64; do
    sudo -n test -f "$REFIND/drivers_x64/${drv}.efi" \
        && ok "driver: ${drv}.efi present" \
        || bad "driver: ${drv}.efi MISSING"
done

# Theme assets (if enabled in boot.json)
THEME_ENABLED=$(jq -r '.refind.install.theme.enabled // false' "$BOOT_JSON")
if [ "$THEME_ENABLED" = "true" ]; then
    THEME_NAME=$(jq -r '.refind.install.theme.name' "$BOOT_JSON")
    # Data-driven: the included theme conf filename is .refind.install.theme.theme_conf
    # (same default as render-refind-conf.sh). Hardcoding "theme.conf" here produced
    # a false FAIL when boot.json declares "mocha.conf" (the real, deployed file).
    THEME_CONF_NAME=$(jq -r '.refind.install.theme.theme_conf // "theme.conf"' "$BOOT_JSON")
    sudo -n test -d "$REFIND/themes/$THEME_NAME" \
        && ok "theme dir themes/$THEME_NAME/ present" \
        || bad "theme dir themes/$THEME_NAME/ MISSING"
    THEME_CONF="$REFIND/themes/$THEME_NAME/$THEME_CONF_NAME"
    sudo -n test -f "$THEME_CONF" && ok "$THEME_CONF_NAME present" || bad "$THEME_CONF_NAME missing"
    # Verify every path the deployed theme.conf references resolves
    if sudo -n test -f "$THEME_CONF"; then
        sudo -n awk '/^(icons_dir|banner|selection_big|selection_small|font) /{print $1, $2}' "$THEME_CONF" |
            while read -r kind p; do
                # icons_dir is a directory; rest are files.
                if [ "$kind" = "icons_dir" ]; then
                    sudo -n test -d "$REFIND/$p" && ok "    theme $kind $p" || bad "    theme $kind $p MISSING"
                else
                    sudo -n test -f "$REFIND/$p" && ok "    theme $kind $p" || bad "    theme $kind $p MISSING"
                fi
            done
    fi
fi

# ── T-C: refind.conf loader paths resolve ──────────────────────────────────
hdr "T-C refind.conf loader paths"
CONF="$REFIND/refind.conf"
if sudo -n test -f "$CONF"; then
    # For each menuentry block, capture the label + loader. Walk per-volume.
    sudo -n awk '
        /^menuentry/  { name=$0; vol=""; ldr=""; }
        /^[ \t]+volume/ { vol=$2; gsub("\"", "", vol) }
        /^[ \t]+loader/ { ldr=$2; printf "%s\t%s\t%s\n", vol, ldr, name }
    ' "$CONF" | sort -u | while IFS="$(printf '\t')" read -r vol ldr name; do
        label=$(echo "$name" | sed 's/^menuentry "\([^"]*\)".*/\1/')
        case "$ldr" in
            /kernels/*)
                if sudo -n test -f "$BOOT_DIR$ldr"; then
                    ok "[$label] loader=$ldr  →  $BOOT_DIR$ldr"
                else
                    bad "[$label] loader=$ldr  MISSING on $BOOT_DIR"
                fi
                ;;
            /EFI/*)
                # If volume is the ESP UUID, look in $ESP_DIR; else skip (foreign volume)
                if [ "$vol" = "$ESP_UUID" ]; then
                    if sudo -n test -f "$ESP_DIR$ldr"; then
                        ok "[$label] loader=$ldr  →  $ESP_DIR$ldr"
                    else
                        bad "[$label] loader=$ldr  MISSING on ESP"
                    fi
                else
                    note "[$label] loader=$ldr volume=$vol  (external — can't verify here)"
                fi
                ;;
            *) note "[$label] loader=$ldr  (unrecognised path style)";;
        esac
    done
fi

# ── T-Cv: every rEFInd `volume` identifier actually resolves ───────────────
# rEFInd's `volume` token matches ONLY a filesystem LABEL, a partition label
# (PARTLABEL), or a partition GPT GUID (PARTUUID) — plus the FAT volume serial
# (XXXX-XXXX) it stores for FAT ESP/USB. It does NOT match an ext4 filesystem
# UUID. This is the check that was missing: T-C above prints "external — can't
# verify" for non-ESP volumes and never confirms the identifier resolves at
# all, so a stanza with volume=<ext4 fs-UUID> passed audit yet gave "kernel not
# found" at boot (BlissOS/my-konsole, 2026-07-10). We reproduce rEFInd's rule
# so a fs-UUID that is NOT also a PARTUUID FAILS here, before a reboot.
hdr "T-Cv rEFInd volume identifiers resolve (label / PARTLABEL / PARTUUID)"
if sudo -n test -f "$CONF"; then
    sudo -n grep -oE '^[ \t]+volume[ \t]+"[^"]+"' "$CONF" \
        | sed -E 's/^[ \t]+volume[ \t]+"([^"]+)"/\1/' | sort -u | while read -r vol; do
        [ -n "$vol" ] || continue
        if echo "$vol" | grep -qiE '^[0-9a-f]{4}-[0-9a-f]{4}$'; then
            # FAT volume serial (ESP / Ventoy USB) — rEFInd matches these.
            if sudo -n blkid -U "$vol" >/dev/null 2>&1; then
                ok "volume \"$vol\"  (FAT volume serial → $(sudo -n blkid -U "$vol"))"
            else
                # A FAT serial that isn't present is almost always a removable
                # device not currently connected (e.g. the Ventoy USB) — not a
                # boot regression. Surface it, don't fail the audit.
                note "volume \"$vol\"  (FAT volume serial not present — removable/USB not connected?)"
            fi
        elif echo "$vol" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
            # Full UUID form — rEFInd treats this as a PARTITION GUID (PARTUUID),
            # NOT a filesystem UUID. Must resolve as a PARTUUID.
            dev=$(sudo -n blkid -o device -t PARTUUID="$vol" 2>/dev/null | head -1)
            if [ -n "$dev" ]; then
                ok "volume \"$vol\"  (PARTUUID → $dev)"
            elif sudo -n blkid -U "$vol" >/dev/null 2>&1; then
                bad "volume \"$vol\"  is a FILESYSTEM UUID, not a PARTUUID — rEFInd CANNOT match it (→ 'kernel not found'). Use the fs label or the partition's PARTUUID ($(sudo -n blkid -o value -s PARTUUID $(sudo -n blkid -U "$vol") 2>/dev/null))."
            else
                bad "volume \"$vol\"  matches no PARTUUID and no filesystem on disk"
            fi
        else
            # Bare string — a filesystem LABEL or a partition PARTLABEL.
            if sudo -n blkid -L "$vol" >/dev/null 2>&1; then
                ok "volume \"$vol\"  (filesystem label → $(sudo -n blkid -L "$vol"))"
            elif sudo -n blkid -o device -t PARTLABEL="$vol" 2>/dev/null | grep -q .; then
                ok "volume \"$vol\"  (partition label → $(sudo -n blkid -o device -t PARTLABEL="$vol" | head -1))"
            else
                bad "volume \"$vol\"  matches no filesystem label or PARTLABEL on disk"
            fi
        fi
    done
fi

# ── T-Cw: loader (and initrd) files EXIST on their resolved volume ─────────
# T-Cv proves the volume identifier resolves; this proves the pointed-at files
# are actually there. Catches the dangling-entry class twice hit in practice:
# a correct stanza whose target was never populated (empty /blissos on p5;
# empty p8 before install-partition ran, 2026-07-10). For every stanza whose
# volume resolves to a LOCAL block device, RO-mount it (or reuse the existing
# mountpoint) and test -f each declared path. Unresolvable volumes were
# already reported by T-Cv; removable ones are skipped there too.
hdr "T-Cw loader/initrd files exist on their volume"
if sudo -n test -f "$CONF"; then
    sudo -n awk '
        /^menuentry/    { vol=""; ldr=""; ird="" }
        /^[ \t]+volume/ { vol=$2; gsub("\"", "", vol) }
        /^[ \t]+initrd/ { ird=$2 }
        /^[ \t]+loader/ { ldr=$2 }
        /^\}/           { if (vol != "" && ldr != "") printf "%s\t%s\t%s\n", vol, ldr, ird }
    ' "$CONF" | sort -u | while IFS="$(printf '\t')" read -r vol ldr ird; do
        # Resolve the volume the same way rEFInd does (label / PARTLABEL /
        # PARTUUID / FAT serial) to a local device; skip if absent (T-Cv's job).
        # Every lookup is `|| true`-guarded: the script runs under set -eu and
        # blkid exits 2 on no-match (e.g. the unplugged Ventoy USB), which
        # would otherwise abort the whole audit mid-loop.
        dev=$(sudo -n blkid -L "$vol" 2>/dev/null || true)
        [ -n "$dev" ] || dev=$(sudo -n blkid -o device -t PARTLABEL="$vol" 2>/dev/null | head -1 || true)
        [ -n "$dev" ] || dev=$(sudo -n blkid -o device -t PARTUUID="$vol" 2>/dev/null | head -1 || true)
        [ -n "$dev" ] || dev=$(sudo -n blkid -U "$vol" 2>/dev/null || true)
        [ -n "$dev" ] || { note "volume \"$vol\" not present — files not checkable (see T-Cv)"; continue; }
        # Reuse a live mountpoint when the device is already mounted; else RO-mount.
        mp=$(findmnt -n -o TARGET --source "$dev" 2>/dev/null | head -1 || true)
        tmp_mp=""
        if [ -z "$mp" ]; then
            tmp_mp=$(mktemp -d) && sudo -n mount -o ro "$dev" "$tmp_mp" 2>/dev/null \
                || { rmdir "$tmp_mp" 2>/dev/null; note "volume \"$vol\" ($dev): cannot RO-mount to check files"; continue; }
            mp="$tmp_mp"
        fi
        if sudo -n test -f "$mp$ldr"; then
            ok "[$vol] loader $ldr exists ($dev)"
        else
            bad "[$vol] loader $ldr MISSING on $dev — dangling boot entry (populate the volume or drop the stanza)"
        fi
        if [ -n "$ird" ]; then
            if sudo -n test -f "$mp$ird"; then
                ok "[$vol] initrd $ird exists"
            else
                bad "[$vol] initrd $ird MISSING on $dev"
            fi
        fi
        # `if` form, not `[ ] && { }` — under set -e a false && as the loop
        # body's last command would abort the script.
        if [ -n "$tmp_mp" ]; then
            sudo -n umount "$tmp_mp" 2>/dev/null || true
            rmdir "$tmp_mp" 2>/dev/null || true
        fi
    done
fi

# ── T-D: kernel/initrd magic bytes ─────────────────────────────────────────
hdr "T-D kernel + initrd binary integrity"
if sudo -n test -f "$CONF"; then
    sudo -n grep -oE '/kernels/[a-z0-9-]+(linux|initrd)[^ "]*' "$CONF" | sort -u | while read -r p; do
        full="$BOOT_DIR$p"
        if ! sudo -n test -f "$full"; then
            bad "$p MISSING"
            continue
        fi
        sz=$(sudo -n stat -c %s "$full")
        case "$p" in
            *linux*bzImage)
                # Linux kernel: bytes 0x202..0x205 = "HdrS" magic
                magic=$(sudo -n dd if="$full" bs=1 count=4 skip=514 2>/dev/null | tr -d '\0')
                if [ "$magic" = "HdrS" ]; then
                    ok "[kernel] $p  ($sz bytes, HdrS magic)"
                else
                    bad "[kernel] $p  ($sz bytes, NO HdrS magic — corrupt?)"
                fi
                ;;
            *initrd*)
                # Initrd: gzip header (1f 8b), zstd (28 b5 2f fd), xz (fd 37 7a),
                # cpio newc (30 37 30 37 == ASCII '0707' — first 4 bytes of '070701')
                head=$(sudo -n head -c 4 "$full" | od -An -tx1 | tr -d ' ')
                case "$head" in
                    1f8b*) ok "[initrd] $p  ($sz bytes, gzip)" ;;
                    28b5*) ok "[initrd] $p  ($sz bytes, zstd)" ;;
                    fd37*) ok "[initrd] $p  ($sz bytes, xz)" ;;
                    3037*) ok "[initrd] $p  ($sz bytes, cpio-newc uncompressed)" ;;
                    *)     note "[initrd] $p  ($sz bytes, unknown magic $head)" ;;
                esac
                ;;
            *) note "$p  (unclassified path)";;
        esac
    done
fi

# ── T-E: GRUB EFI binary ───────────────────────────────────────────────────
hdr "T-E GRUB binary"
GRUB_DIR_REL=$(jq -r '.grub.install.efi_install_dir' "$BOOT_JSON")
GRUB_BIN="$ESP_DIR$GRUB_DIR_REL/grubx64.efi"
sudo -n test -f "$GRUB_BIN" \
    && sudo -n file "$GRUB_BIN" 2>&1 | grep -q "PE32+ executable" \
    && ok "$GRUB_BIN present + valid PE32+ ($(sudo -n stat -c %s "$GRUB_BIN") bytes)" \
    || bad "$GRUB_BIN missing or invalid"

# ── T-F: GRUB modules + font on /boot ──────────────────────────────────────
hdr "T-F GRUB modules + font on /boot"
mods=$(sudo -n ls "$BOOT_DIR/grub/x86_64-efi/" 2>/dev/null | wc -l)
[ "$mods" -gt 200 ] && ok "GRUB modules: $mods files in /boot/grub/x86_64-efi/" || bad "GRUB modules: only $mods files"
sudo -n test -f "$BOOT_DIR/grub/fonts/unicode.pf2" \
    && ok "unicode.pf2 present ($(sudo -n stat -c %s "$BOOT_DIR/grub/fonts/unicode.pf2") bytes)" \
    || bad "unicode.pf2 MISSING"
sudo -n test -f "$BOOT_DIR/grub/grub.cfg" \
    && ok "grub.cfg present" \
    || bad "grub.cfg MISSING"

# ── T-G: grub.cfg has menuentry per linux_order key ───────────────────────
hdr "T-G grub.cfg has every distro from boot.json"
for key in $(jq -r '.grub.linux_order[]?' "$BOOT_JSON"); do
    label=$(jq -r ".grub.menu.$key.label" "$BOOT_JSON")
    if sudo -n grep -qF "menuentry \"$label\"" "$BOOT_DIR/grub/grub.cfg"; then
        ok "grub.cfg has '$label' (key=$key)"
    else
        bad "grub.cfg MISSING '$label' (key=$key)"
    fi
done

# ── T-H: per-linux-partition soft-boot integrity ──────────────────────────
hdr "T-H Linux partition soft-boot integrity (Kali, Debian)"
TMPMNT=$(mktemp -d -p /tmp aa-bootloader-verify.XXXXXX)
trap 'sudo -n umount "$TMPMNT" 2>/dev/null || true; rmdir "$TMPMNT" 2>/dev/null || true' EXIT

for key in $(jq -r '.grub.linux_order[]?' "$BOOT_JSON"); do
    UUID=$(jq -r ".grub.menu.$key.root_uuid" "$BOOT_JSON")
    KERN=$(jq -r ".grub.menu.$key.kernel" "$BOOT_JSON")
    INIT=$(jq -r ".grub.menu.$key.initrd" "$BOOT_JSON")
    LBL=$(jq -r ".grub.menu.$key.label" "$BOOT_JSON")

    DEV=$(sudo -n blkid -U "$UUID" 2>/dev/null)
    if [ -z "$DEV" ]; then
        bad "[$LBL] device with UUID=$UUID not present"
        continue
    fi

    # Mount RO; if already mounted somewhere just inspect there.
    MNT=$(findmnt -n -o TARGET --source "$DEV" 2>/dev/null | head -1)
    if [ -z "$MNT" ]; then
        if sudo -n mount -o ro "$DEV" "$TMPMNT" 2>/dev/null; then
            MNT="$TMPMNT"
            ok "[$LBL] mounted $DEV at $MNT (read-only)"
        else
            bad "[$LBL] failed to mount $DEV (UUID=$UUID)"
            continue
        fi
    else
        ok "[$LBL] $DEV already mounted at $MNT"
    fi

    # /vmlinuz must resolve
    if sudo -n test -L "$MNT$KERN" || sudo -n test -f "$MNT$KERN"; then
        target=$(sudo -n readlink -f "$MNT$KERN" 2>/dev/null || echo "$MNT$KERN")
        if sudo -n test -f "$target"; then
            sz=$(sudo -n stat -c %s "$target")
            magic=$(sudo -n dd if="$target" bs=1 count=4 skip=514 2>/dev/null | tr -d '\0')
            if [ "$magic" = "HdrS" ]; then
                ok "[$LBL] $KERN → $target ($sz bytes, valid Linux kernel)"
            else
                bad "[$LBL] $KERN → $target ($sz bytes) — NO HdrS magic"
            fi
        else
            bad "[$LBL] $KERN → $target — symlink target missing"
        fi
    else
        bad "[$LBL] $KERN MISSING on $MNT"
    fi

    # /initrd.img must resolve
    if sudo -n test -L "$MNT$INIT" || sudo -n test -f "$MNT$INIT"; then
        target=$(sudo -n readlink -f "$MNT$INIT" 2>/dev/null || echo "$MNT$INIT")
        if sudo -n test -f "$target"; then
            sz=$(sudo -n stat -c %s "$target")
            head=$(sudo -n head -c 4 "$target" | od -An -tx1 | tr -d ' ')
            case "$head" in
                1f8b*) ok "[$LBL] $INIT → $target ($sz bytes, gzip)" ;;
                28b5*) ok "[$LBL] $INIT → $target ($sz bytes, zstd)" ;;
                fd37*) ok "[$LBL] $INIT → $target ($sz bytes, xz)" ;;
                3037*) ok "[$LBL] $INIT → $target ($sz bytes, cpio-newc uncompressed)" ;;
                *) note "[$LBL] $INIT → $target ($sz bytes, magic $head — unknown)" ;;
            esac
        else
            bad "[$LBL] $INIT → $target — symlink target missing"
        fi
    else
        bad "[$LBL] $INIT MISSING on $MNT"
    fi

    # /etc/fstab references real filesystems
    if sudo -n test -f "$MNT/etc/fstab"; then
        bad_fstab=0
        for fs_uuid in $(sudo -n awk '$1 !~ /^#/ && $1 ~ /UUID=/ {sub("UUID=","",$1); print $1}' "$MNT/etc/fstab" 2>/dev/null); do
            if ! sudo -n blkid 2>/dev/null | grep -q "$fs_uuid"; then
                bad "[$LBL] /etc/fstab references unknown UUID=$fs_uuid"
                bad_fstab=$((bad_fstab+1))
            fi
        done
        [ "$bad_fstab" -eq 0 ] && ok "[$LBL] /etc/fstab UUIDs all resolve"
    else
        note "[$LBL] no /etc/fstab (acceptable for some minimal systems)"
    fi

    # Unmount only if WE mounted it
    if [ "$MNT" = "$TMPMNT" ]; then
        sudo -n umount "$TMPMNT" 2>/dev/null || true
    fi
done

# ── T-I: NVRAM cross-check ─────────────────────────────────────────────────
hdr "T-I NVRAM ↔ boot.json"
EFIBOOTMGR=$(command -v efibootmgr 2>/dev/null || echo /run/current-system/sw/bin/efibootmgr)
if [ -x "$EFIBOOTMGR" ]; then
    nvram=$(sudo -n "$EFIBOOTMGR")
    # Default entry from boot.json must exist in NVRAM
    DEFAULT_NAME=$(jq -r '.uefi.nvram.entries[]? | select(.default == true) | .name' "$BOOT_JSON")
    echo "$nvram" | grep -q "\\* $DEFAULT_NAME" \
        && ok "NVRAM has default entry '$DEFAULT_NAME'" \
        || bad "NVRAM MISSING default entry '$DEFAULT_NAME'"
    # rEFInd entry must exist (added by install-refind.sh, not in entries[])
    REFIND_LBL=$(jq -r '.refind.install.nvram_label' "$BOOT_JSON")
    echo "$nvram" | grep -q "\\* $REFIND_LBL" \
        && ok "NVRAM has '$REFIND_LBL'" \
        || bad "NVRAM MISSING '$REFIND_LBL'"
    # remove_stale entries should NOT exist
    for stale in $(jq -r '.uefi.nvram.remove_stale[]?' "$BOOT_JSON"); do
        if echo "$nvram" | grep -q "\\* $stale"; then
            bad "stale NVRAM entry '$stale' still present (apply.sh should have removed it)"
        else
            ok "stale '$stale' purged"
        fi
    done
    # rEFInd at top of BootOrder. efibootmgr prints lines like:
    #   "Boot0007* rEFInd\tHD(1,GPT,...)/\EFI\refind\refind_x64.efi"
    # Match the name followed by tab/space/EOL (same pattern as render-nvram's
    # find_entry) — anchoring to the bare name fails because of the trailing path.
    first=$(echo "$nvram" | awk '/^BootOrder:/ {print $2}' | cut -d, -f1)
    refind_id=$(echo "$nvram" | awk -v n="$REFIND_LBL" '
        match($0, /^Boot[0-9A-Fa-f]+\* /) {
            rest = substr($0, RLENGTH + 1)
            if (rest == n || index(rest, n "\t") == 1 || index(rest, n " ") == 1) {
                print substr($0, 5, RLENGTH - 6); exit
            }
        }')
    [ -n "$refind_id" ] && [ "$first" = "$refind_id" ] \
        && ok "$REFIND_LBL is first in BootOrder (Boot$first)" \
        || bad "BootOrder first=$first, $REFIND_LBL=$refind_id (rEFInd not default)"
else
    bad "efibootmgr not found at $EFIBOOTMGR — can't verify NVRAM"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
if [ "$FAIL" = "0" ]; then
    log "verify-boot-ready: $PASS pass, $WARN warn, 0 FAIL  →  SAFE TO REBOOT"
    exit 0
else
    error "verify-boot-ready: $PASS pass, $WARN warn, $FAIL FAIL  →  DO NOT REBOOT"
    exit 1
fi
