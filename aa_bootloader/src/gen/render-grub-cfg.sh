#!/bin/sh
# render-grub-cfg.sh — full grub.cfg from boot.json + /nix/var/nix/profiles
#
# Phase 3: aa_bootloader becomes the bootloader's SoT. NixOS contributes
# kernel/initrd files in /boot/kernels/ but does NOT author grub.cfg.
# This script reads:
#   - src/boot.json          GRUB UI, modules, multi-OS menu, NixOS rollback policy
#   - $NIX_PROFILES/system*  resolves /nix/store paths for kernel, initrd, init,
#                            kernel-params, specialisations
# Writes:
#   - dist/boot/grub/grub.cfg

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# shellcheck source=lib/log.sh
. "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/json.sh
. "$SCRIPT_DIR/lib/json.sh"

BOOT_JSON="$ROOT_DIR/src/boot.json"
NIX_PROFILES="${NIX_PROFILES:-/nix/var/nix/profiles}"
DIST_GRUB_DIR="$ROOT_DIR/dist/boot/grub"
OUT="$DIST_GRUB_DIR/grub.cfg"

mkdir -p "$DIST_GRUB_DIR"

# Multi-OS: NixOS is just one citizen. If /nix is absent (NixOS not installed,
# or pool not mounted), skip NixOS rendering and continue with Arch/Kali/Win/USB.
if [ -d "$NIX_PROFILES" ]; then
    HAS_NIXOS=1
    log "Rendering grub.cfg (NixOS: $NIX_PROFILES + multi-OS from boot.json)"
else
    HAS_NIXOS=0
    log "Rendering grub.cfg (multi-OS only — $NIX_PROFILES not present, NixOS section skipped)"
fi

BOOT_UUID=$(jq_get '.uefi.boot.uuid')
TIMEOUT=$(jq_get '.grub.ui.timeout')
DEFAULT=$(jq_get '.grub.ui.default')
TIMEOUT_STYLE=$(jq_get '.grub.ui.timeout_style')
GFXMODE=$(jq_get '.grub.ui.gfxmode')
GFXPAYLOAD=$(jq_get '.grub.ui.gfxpayload')
BG_COLOR=$(jq_get '.grub.ui.background_color')
COLOR_NORMAL=$(jq_get '.grub.ui.color_normal')
COLOR_HIGHLIGHT=$(jq_get '.grub.ui.color_highlight')

# /nix/store/<HASH>-<NAME>/<file>  →  /kernels/<HASH>-<NAME>-<file>
nix_store_to_boot_path() {
    target="$1"
    name=${target#/nix/store/}        # HASH-NAME/file
    hashpart=${name%%/*}              # HASH-NAME
    file=${name##*/}                  # bzImage or initrd
    echo "/kernels/${hashpart}-${file}"
}

# Args: label, class, kernel-store, initrd-store, init-path, params, [extra-flags]
emit_menuentry() {
    label="$1"; class="$2"; kernel_store="$3"; initrd_store="$4"
    init_path="$5"; params="$6"; flags="${7:-}"

    kernel_boot=$(nix_store_to_boot_path "$kernel_store")
    initrd_boot=$(nix_store_to_boot_path "$initrd_store")

    cat <<EOF
menuentry "$label" --class $class $flags {
  search --no-floppy --set=drive1 --fs-uuid $BOOT_UUID
  linux (\$drive1)/$kernel_boot init=$init_path $params
  initrd (\$drive1)/$initrd_boot
}

EOF
}

# Args: sys-link-or-dir, label-prefix-or-empty, indent
emit_nixos_generation() {
    sys_link="$1"
    label_prefix="$2"
    indent="${3:-}"

    sys=$(readlink -f "$sys_link" 2>/dev/null) || return 0
    [ -d "$sys" ] || { warn "  $sys_link → $sys: missing"; return 0; }

    kernel=$(readlink "$sys/kernel" 2>/dev/null) || return 0
    initrd=$(readlink "$sys/initrd" 2>/dev/null) || return 0
    init="$sys/init"
    params=$(cat "$sys/kernel-params" 2>/dev/null) || params=""

    if [ -n "$label_prefix" ]; then
        default_label="NixOS - $label_prefix - Default"
        flags=""
    else
        default_label="NixOS - Default"
        flags="--unrestricted"
    fi

    emit_menuentry "$default_label" nixos "$kernel" "$initrd" "$init" "$params" "$flags" \
        | sed "s/^/$indent/"

    if [ -d "$sys/specialisation" ]; then
        for spec_dir in "$sys/specialisation"/*; do
            [ -d "$spec_dir" ] || continue
            spec_name=$(basename "$spec_dir")
            spec_kernel=$(readlink "$spec_dir/kernel" 2>/dev/null) || continue
            spec_initrd=$(readlink "$spec_dir/initrd" 2>/dev/null) || continue
            spec_init="$spec_dir/init"
            spec_params=$(cat "$spec_dir/kernel-params" 2>/dev/null) || spec_params=""

            if [ -n "$label_prefix" ]; then
                spec_label="NixOS - $label_prefix - $spec_name"
            else
                spec_label="NixOS - $spec_name"
            fi
            emit_menuentry "$spec_label" nixos "$spec_kernel" "$spec_initrd" \
                "$spec_init" "$spec_params" "" | sed "s/^/$indent/"
        done
    fi
}

# Multi-OS entries
emit_arch() {
    [ "$(jq -r '.grub.menu.arch.enabled // false' "$BOOT_JSON")" = "true" ] || return 0
    L=$(jq_get '.grub.menu.arch.label')
    U=$(jq_get '.grub.menu.arch.root_uuid')
    K=$(jq_get '.grub.menu.arch.kernel')
    I=$(jq_get '.grub.menu.arch.initrd')
    O=$(jq_get '.grub.menu.arch.options')
    cat <<EOF
menuentry "$L" --class arch --class gnu-linux --class gnu --class os {
  insmod part_gpt
  insmod ext2
  search --no-floppy --fs-uuid --set=root $U
  linux $K root=UUID=$U $O
  initrd $I
}

EOF
    if [ "$(jq -r '.grub.menu.arch.recovery.enabled // false' "$BOOT_JSON")" = "true" ]; then
        RL=$(jq_get '.grub.menu.arch.recovery.label')
        RK=$(jq_get '.grub.menu.arch.recovery.kernel')
        RI=$(jq_get '.grub.menu.arch.recovery.initrd')
        RO=$(jq_get '.grub.menu.arch.recovery.options')
        cat <<EOF
submenu "Arch OS Recovery Mode" --class arch {
  menuentry "$RL" --class arch {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root $U
    linux $RK root=UUID=$U $RO
    initrd $RI
  }
}

EOF
    fi
}

emit_kali() {
    [ "$(jq -r '.grub.menu.kali.enabled // false' "$BOOT_JSON")" = "true" ] || return 0
    L=$(jq_get '.grub.menu.kali.label')
    U=$(jq_get '.grub.menu.kali.root_uuid')
    K=$(jq_get '.grub.menu.kali.kernel')
    I=$(jq_get '.grub.menu.kali.initrd')
    O=$(jq_get '.grub.menu.kali.options')
    cat <<EOF
menuentry "$L" --class kali --class gnu-linux --class gnu --class os {
  insmod part_gpt
  insmod ext2
  search --no-floppy --fs-uuid --set=root $U
  linux $K root=UUID=$U $O
  initrd $I
}

EOF
    if [ "$(jq -r '.grub.menu.kali.recovery.enabled // false' "$BOOT_JSON")" = "true" ]; then
        echo "submenu \"Kali Linux Recovery Mode\" --class kali {"
        jq -c '.grub.menu.kali.recovery.modes[]' "$BOOT_JSON" | while read -r mode; do
            ML=$(echo "$mode" | jq -r '.label')
            MK=$(echo "$mode" | jq -r ".kernel // \"$K\"")
            MI=$(echo "$mode" | jq -r ".initrd // \"$I\"")
            MO=$(echo "$mode" | jq -r '.options')
            cat <<EOF2
  menuentry "$ML" --class kali {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root $U
    linux $MK root=UUID=$U $MO
    initrd $MI
  }
EOF2
        done
        echo "}"
        echo
    fi
}

emit_windows() {
    [ "$(jq -r '.grub.menu.windows.enabled // false' "$BOOT_JSON")" = "true" ] || return 0
    L=$(jq_get '.grub.menu.windows.label')
    U=$(jq_get '.grub.menu.windows.efi_uuid')
    P=$(jq_get '.grub.menu.windows.efi_path')
    cat <<EOF
menuentry "$L" --class windows --class os {
  insmod part_gpt
  insmod fat
  insmod chain
  search --no-floppy --fs-uuid --set=root $U
  chainloader $P
}

EOF
}

emit_usb() {
    [ "$(jq -r '.grub.menu.usb.enabled // false' "$BOOT_JSON")" = "true" ] || return 0
    jq -c '.grub.menu.usb.entries[]' "$BOOT_JSON" | while read -r entry; do
        UL=$(echo "$entry" | jq -r '.label')
        UP=$(echo "$entry" | jq -r '.efi_path')
        UU=$(echo "$entry" | jq -r '.efi_uuid // empty')
        USF=$(echo "$entry" | jq -r '.search_file // empty')
        echo "menuentry \"$UL\" --class usb --class os {"
        echo "  insmod part_gpt"
        echo "  insmod fat"
        echo "  insmod chain"
        if [ -n "$USF" ]; then
            echo "  search --no-floppy --set=root --file $USF"
        else
            echo "  search --no-floppy --fs-uuid --set=root $UU"
        fi
        echo "  chainloader $UP"
        echo "}"
        echo
    done
}

emit_firmware() {
    [ "$(jq -r '.grub.menu.firmware.enabled // false' "$BOOT_JSON")" = "true" ] || return 0
    L=$(jq_get '.grub.menu.firmware.label')
    cat <<EOF
menuentry "$L" --class settings {
  fwsetup
}

EOF
}

emit_rollback_submenu() {
    AUTO=$(jq -r '.grub.menu.nixos.rollback_entries.auto_walk_profiles // false' "$BOOT_JSON")
    MAX=$(jq -r '.grub.menu.nixos.rollback_entries.max // 5' "$BOOT_JSON")
    [ "$AUTO" = "true" ] || return 0

    cur_sys=$(readlink -f "$NIX_PROFILES/system")
    echo "submenu \"NixOS - All configurations\" --class submenu {"
    for link in $(ls -1 "$NIX_PROFILES" 2>/dev/null | grep '^system-[0-9]\+-link$' \
                  | sort -t- -k2 -n -r | head -n "$MAX"); do
        gen_num=$(echo "$link" | sed 's/^system-\([0-9]\+\)-link$/\1/')
        sys_path="$NIX_PROFILES/$link"
        gen_date=$(stat -c %y "$sys_path" 2>/dev/null | cut -d' ' -f1)
        echo "  submenu \"> NixOS - Configuration $gen_num ($gen_date)\" --class submenu {"
        emit_nixos_generation "$sys_path" "Configuration $gen_num" "    "
        echo "  }"
        echo
    done
    echo "}"
}

# ─── Render ─────────────────────────────────────────────────────────────────

{
    cat <<EOF
# AUTO-GENERATED by aa_bootloader/build.sh deploy --target grub
# DO NOT EDIT — regenerated on every deploy from src/boot.json
# Source-of-truth: aa_bootloader/src/boot.json
# Generated: $(date '+%Y-%m-%d %H:%M:%S UTC%z')

set timeout=$TIMEOUT
set timeout_style=$TIMEOUT_STYLE
set gfxmode=$GFXMODE
set gfxpayload=$GFXPAYLOAD

# Locate /boot partition (this cfg lives at \$drive1/grub/grub.cfg)
search --no-floppy --set=drive1 --fs-uuid $BOOT_UUID

# grubenv: support grub-reboot one-time selection
if [ -s \$prefix/grubenv ]; then
  load_env
fi

if [ "\${next_entry}" ]; then
  set default="\${next_entry}"
  set next_entry=
  save_env next_entry
  set timeout=1
  set boot_once=true
else
  set default=$DEFAULT
  set timeout=$TIMEOUT
fi

function savedefault {
  if [ -z "\${boot_once}" ]; then
    saved_entry="\${chosen}"
    save_env saved_entry
  fi
}

# ─── Modules ────────────────────────────────────────────────────────────────

EOF
    jq -r '.grub.modules[]' "$BOOT_JSON" | sed 's/^/insmod /'

    cat <<EOF

# ─── UI ─────────────────────────────────────────────────────────────────────

if loadfont (\$drive1)/grub/fonts/unicode.pf2 ; then
  insmod gfxterm
  set gfxmode=$GFXMODE
  set gfxpayload=$GFXPAYLOAD
  terminal_output gfxterm
elif loadfont (\$drive1)/converted-font.pf2 ; then
  insmod gfxterm
  set gfxmode=$GFXMODE
  set gfxpayload=$GFXPAYLOAD
  terminal_output gfxterm
fi

background_color '$BG_COLOR'

if background_image --mode 'normal' (\$drive1)/background.png; then
  set color_normal=$COLOR_NORMAL
  set color_highlight=$COLOR_HIGHLIGHT
fi

# ═══════════════════════════════════════════════════════════════════════════
# NixOS — current generation
# ═══════════════════════════════════════════════════════════════════════════

EOF
    if [ "$HAS_NIXOS" = "1" ]; then
        emit_nixos_generation "$NIX_PROFILES/system" ""
    else
        echo "# (NixOS not installed — section omitted)"
        echo
    fi

    cat <<EOF
# ═══════════════════════════════════════════════════════════════════════════
# Multi-OS (from src/boot.json)
# ═══════════════════════════════════════════════════════════════════════════

EOF
    emit_arch
    emit_kali
    emit_windows
    emit_usb
    emit_firmware

    if [ "$HAS_NIXOS" = "1" ]; then
        cat <<EOF
# ═══════════════════════════════════════════════════════════════════════════
# NixOS — rollback (older generations)
# ═══════════════════════════════════════════════════════════════════════════

EOF
        emit_rollback_submenu
    fi
} > "$OUT"

log "Wrote: $OUT  ($(wc -l < "$OUT") lines)"
