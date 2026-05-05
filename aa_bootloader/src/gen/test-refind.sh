#!/bin/sh
PASS=0; FAIL=0; WARN=0
g='\033[0;32m'; r='\033[0;31m'; y='\033[1;33m'; n='\033[0m'
ok()   { printf "${g}✓${n} %s\n" "$1"; PASS=$((PASS+1)); }
bad()  { printf "${r}✗${n} %s\n" "$1"; FAIL=$((FAIL+1)); }
warn() { printf "${y}!${n} %s\n" "$1"; WARN=$((WARN+1)); }
hdr()  { printf "\n\033[1;36m── %s ──\033[0m\n" "$1"; }

ESP=/mnt/efi
REFIND=$ESP/EFI/refind
CONF=$REFIND/refind.conf

# 1. Files present
hdr "1. ESP /EFI/refind/ tree"
[ -f "$REFIND/refind_x64.efi" ] && ok "refind_x64.efi present" || bad "refind_x64.efi MISSING"
[ -f "$CONF" ] && ok "refind.conf present" || bad "refind.conf MISSING"
[ -d "$REFIND/drivers_x64" ] && ok "drivers_x64/ dir present" || bad "drivers_x64/ MISSING"
[ -f "$REFIND/drivers_x64/btrfs_x64.efi" ] && ok "  btrfs_x64.efi" || bad "  MISSING btrfs driver"
[ -f "$REFIND/drivers_x64/ext4_x64.efi" ]  && ok "  ext4_x64.efi"  || bad "  MISSING ext4 driver"
[ -d "$REFIND/icons" ] && ok "icons/ dir ($(ls "$REFIND/icons" | wc -l) files)" || warn "icons/ missing"

# 2. EFI binary validity
hdr "2. EFI binary integrity"
file "$REFIND/refind_x64.efi" 2>&1 | grep -q "PE32+ executable for EFI" && ok "refind_x64.efi is valid PE32+ EFI" || bad "refind_x64.efi NOT valid"
for d in btrfs_x64 ext4_x64 iso9660_x64; do
    file "$REFIND/drivers_x64/${d}.efi" 2>&1 | grep -q "PE32+ executable for EFI" && ok "$d.efi valid" || warn "$d.efi not valid PE32+"
done

# 3. refind.conf syntax sanity
hdr "3. refind.conf structure"
total_lines=$(wc -l < "$CONF")
ok "$total_lines lines"
n_menu=$(grep -cE '^menuentry' "$CONF")
n_sub=$(grep -cE '^[[:space:]]+submenuentry' "$CONF")
[ "$n_menu" -ge 6 ] && ok "$n_menu top-level menuentries" || bad "Only $n_menu menuentries"
[ "$n_sub" -ge 10 ] && ok "$n_sub submenuentries (rollback gens)" || warn "$n_sub submenuentries"

# Check brace balance
opens=$(grep -cE '\{$' "$CONF")
closes=$(grep -cE '^[[:space:]]*\}$' "$CONF")
[ "$opens" = "$closes" ] && ok "brace balance: $opens { = $closes }" || bad "brace imbalance: $opens { vs $closes }"

# Check for empty loaders (the bug we fixed earlier)
empty_loaders=$(grep -cE '^[[:space:]]+loader[[:space:]]*$' "$CONF")
[ "$empty_loaders" = "0" ] && ok "no empty loader= lines" || bad "$empty_loaders empty loader lines"

# Check default_selection has matching entry
default=$(awk '/^default_selection/ {gsub(/"/,""); print $2}' "$CONF")
if grep -qE "^menuentry \"$default" "$CONF"; then
    ok "default_selection \"$default\" matches a menuentry"
else
    warn "default_selection \"$default\" does NOT prefix-match any menuentry"
fi

# Check scanfor mode
scanfor=$(awk '/^scanfor/ {print $2}' "$CONF")
[ "$scanfor" = "manual" ] && ok "scanfor=manual (Mode B, no autodetect)" || warn "scanfor=$scanfor (autodetect on)"

# 4. UUIDs in stanzas resolve to real partitions
hdr "4. Volume UUIDs referenced"
for uuid in $(grep -oE 'volume "[0-9a-fA-F-]{36}"' "$CONF" | tr -d '"' | awk '{print $2}' | sort -u); do
    if blkid 2>/dev/null | grep -qi "$uuid"; then
        ok "$uuid found on disk"
    else
        bad "$uuid NOT found on disk"
    fi
done
# vfat ESP UUID (8-char form like 2CE0-6722)
for uuid in $(grep -oE 'volume "[0-9A-F]{4}-[0-9A-F]{4}"' "$CONF" | tr -d '"' | awk '{print $2}' | sort -u); do
    if blkid 2>/dev/null | grep -qi "$uuid"; then
        ok "$uuid (FAT) found on disk"
    else
        warn "$uuid (FAT) not currently mounted (Ventoy USB?)"
    fi
done

# 5. /boot/kernels referenced files exist
hdr "5. /boot/kernels references"
miss=0
for path in $(grep -oE 'loader /kernels/[a-zA-Z0-9._+-]+' "$CONF" | awk '{print $2}' | sort -u); do
    if [ -f "/run/media/diego/boot$path" ]; then
        ok "$(basename "$path")"
    else
        bad "MISSING: /run/media/diego/boot$path"
        miss=$((miss+1))
    fi
done
for path in $(grep -oE 'initrd /kernels/[a-zA-Z0-9._+-]+' "$CONF" | awk '{print $2}' | sort -u); do
    [ -f "/run/media/diego/boot$path" ] && ok "$(basename "$path")" || { bad "MISSING: $path"; miss=$((miss+1)); }
done

# 6. /nix/store init paths
hdr "6. /nix/store init paths in refind.conf"
for path in $(grep -oE 'init=/nix/store/[a-zA-Z0-9._+-]*/(specialisation/[a-z-]*/)?init' "$CONF" | sort -u | sed 's/^init=//'); do
    [ -e "$path" ] && ok "$(echo "$path" | head -c 60)..." || bad "MISSING: $path"
done

# 7. NVRAM
hdr "7. NVRAM"
sudo efibootmgr 2>/dev/null | grep -q "rEFInd" && ok "rEFInd NVRAM entry exists" || bad "rEFInd entry MISSING"
sudo efibootmgr 2>/dev/null | grep -q "NixOS-boot-efi" && ok "NixOS-boot-efi (GRUB fallback) exists" || warn "GRUB fallback NVRAM gone"
boot_order_first=$(sudo efibootmgr 2>/dev/null | awk '/^BootOrder:/ {print $2}' | cut -d, -f1)
refind_id=$(sudo efibootmgr 2>/dev/null | awk '/rEFInd/ {gsub(/Boot/,""); gsub(/\*.*/,""); print; exit}')
[ "$boot_order_first" = "$refind_id" ] && ok "rEFInd is first in BootOrder (default)" || warn "BootOrder first=$boot_order_first, rEFInd=$refind_id"
dup=$(sudo efibootmgr 2>/dev/null | grep -c "rEFInd")
[ "$dup" = "1" ] && ok "exactly 1 rEFInd NVRAM entry (no dups)" || bad "$dup rEFInd entries (dups!)"

# 8. dist/ ↔ ESP consistency
hdr "8. dist/ ↔ ESP consistency"
DIST=/run/media/diego/pool/@home-diego/git/unix/aa_bootloader/dist/boot/efi/EFI/refind
cmp -s "$DIST/refind.conf" "$CONF" && ok "refind.conf matches dist/" || warn "refind.conf differs from dist/ (re-run deploy)"
cmp -s "$DIST/refind_x64.efi" "$REFIND/refind_x64.efi" && ok "refind_x64.efi matches dist/" || warn "binary differs from dist/"

# Summary
printf "\n\033[1m═══════════════════════════════════════════════════\033[0m\n"
printf "\033[1mRefind health:\033[0m  ${g}%d pass${n}  ${y}%d warn${n}  ${r}%d fail${n}\n" "$PASS" "$WARN" "$FAIL"
[ $FAIL -eq 0 ] && printf "${g}✓ rEFInd HEALTHY — boot expected to succeed${n}\n" || printf "${r}✗ rEFInd HAS ISSUES${n}\n"
exit $FAIL
