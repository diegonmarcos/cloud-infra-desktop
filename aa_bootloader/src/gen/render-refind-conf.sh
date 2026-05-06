#!/bin/sh
# render-refind-conf.sh — boot.json → dist/boot/efi/EFI/refind/refind.conf
#
# Mode B (manual-only): the menu is exactly what `refind.manual_stanzas.order`
# in boot.json says, in that exact order, with the labels specified there.
# No autodetect, no surprises.
#
# Each order entry has:
#   producer   built-in renderer name (see PRODUCERS section below)
#   label      display name (overrides any source label)
#   from       optional source key (e.g. "kali" → grub.menu.kali)
#   max        producer-specific limit (e.g. rollback gens)
#
# Producers:
#   nixos_primary     current /nix/var/nix/profiles/system → top-level menuentry
#   nixos_rescue      specialisation/rescue → top-level menuentry
#   nixos_safegfx     specialisation/safe-graphics → top-level menuentry
#   nixos_rollback    submenu with last N gens (default + rescue + safegfx each)
#   linux_partition   reads grub.menu.<from> for kernel/initrd/uuid/options
#   usb_chainload     reads grub.menu.usb.entries[] where id == <from>
#   windows_chainload reads grub.menu.windows
#   refind_self       chainloads /EFI/refind/refind_x64.efi (config reload)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# shellcheck source=lib/log.sh
. "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/json.sh
. "$SCRIPT_DIR/lib/json.sh"

BOOT_JSON="$ROOT_DIR/src/boot.json"
NIX_PROFILES="${NIX_PROFILES:-/nix/var/nix/profiles}"
OUT_DIR="$ROOT_DIR/dist/boot/efi/EFI/refind"
OUT="$OUT_DIR/refind.conf"

mkdir -p "$OUT_DIR"
log "Rendering refind.conf"

TIMEOUT=$(jq -r '.refind.ui.timeout // 5' "$BOOT_JSON")
DEFAULT=$(jq -r '.refind.ui.default_selection // "NixOS"' "$BOOT_JSON")
RESOLUTION=$(jq -r '.refind.ui.resolution // "max"' "$BOOT_JSON")
SHOWTOOLS=$(jq -r '.refind.ui.showtools | join(",")' "$BOOT_JSON")
SCANFOR=$(jq -r '.refind.scan.scanfor | join(",")' "$BOOT_JSON")
DONT_SCAN_DIRS=$(jq -r '.refind.scan.dont_scan_dirs | join(",")' "$BOOT_JSON")
ESP_UUID=$(jq -r '.uefi.esp.uuid' "$BOOT_JSON")

# ── Theme path resolution (data-driven, FIRE RULE 4) ──────────────────────
# Producers must NOT hardcode /EFI/refind/icons/. Compute the theme-icons
# base path once here and let every emit_* / producer_* use $ICON_PATH.
# Falls back to the legacy /EFI/refind/icons/ when no theme is enabled.
THEME_ENABLED=$(jq -r '.refind.install.theme.enabled // false' "$BOOT_JSON")
if [ "$THEME_ENABLED" = "true" ]; then
    THEME_NAME=$(jq -r '.refind.install.theme.name' "$BOOT_JSON")
    THEME_ICON_SET=$(jq -r '.refind.install.theme.icon_set // "256-96"' "$BOOT_JSON")
    ICON_PATH="themes/${THEME_NAME}/icons/${THEME_ICON_SET}"
else
    ICON_PATH="/EFI/refind/icons"
fi

# /nix/store/<HASH>-<NAME>/<file>  →  <HASH>-<NAME>-<file> (matches /boot/kernels)
nix_to_boot_name() {
    target="$1"; name=${target#/nix/store/}
    echo "${name%%/*}-${name##*/}"
}

# ════════════════════════════════════════════════════════════════════════════
# PRODUCERS — each takes a label as $1 and writes one or more menuentry blocks
# ════════════════════════════════════════════════════════════════════════════

emit_nixos_one() {
    label="$1"; init_path="$2"; kernel_store="$3"; initrd_store="$4"; params="$5"
    icon="${6:-${ICON_PATH}/os_nixos.png}"
    kboot=$(nix_to_boot_name "$kernel_store")
    iboot=$(nix_to_boot_name "$initrd_store")
    cat <<EOF
menuentry "$label" {
    icon $icon
    volume "boot"
    loader /kernels/$kboot
    initrd /kernels/$iboot
    options "init=$init_path $params"
}

EOF
}

producer_nixos_primary() {
    label="$1"
    [ -d "$NIX_PROFILES" ] || { warn "  $label: /nix not mounted, skipping"; return 0; }
    sys=$(readlink -f "$NIX_PROFILES/system" 2>/dev/null) || return 0
    [ -d "$sys" ] || return 0
    kernel=$(readlink "$sys/kernel" 2>/dev/null) || return 0
    initrd=$(readlink "$sys/initrd" 2>/dev/null) || return 0
    params=$(cat "$sys/kernel-params" 2>/dev/null || echo "")
    emit_nixos_one "$label" "$sys/init" "$kernel" "$initrd" "$params"
}

producer_nixos_rescue() {
    label="$1"
    [ -d "$NIX_PROFILES" ] || { warn "  $label: /nix not mounted, skipping"; return 0; }
    sys=$(readlink -f "$NIX_PROFILES/system" 2>/dev/null) || return 0
    spec="$sys/specialisation/rescue"
    [ -d "$spec" ] || { warn "  $label: rescue specialisation not found"; return 0; }
    kernel=$(readlink "$spec/kernel" 2>/dev/null) || return 0
    initrd=$(readlink "$spec/initrd" 2>/dev/null) || return 0
    params=$(cat "$spec/kernel-params" 2>/dev/null || echo "")
    emit_nixos_one "$label" "$spec/init" "$kernel" "$initrd" "$params"
}

producer_nixos_safegfx() {
    label="$1"
    [ -d "$NIX_PROFILES" ] || return 0
    sys=$(readlink -f "$NIX_PROFILES/system" 2>/dev/null) || return 0
    spec="$sys/specialisation/safe-graphics"
    [ -d "$spec" ] || return 0
    kernel=$(readlink "$spec/kernel" 2>/dev/null) || return 0
    initrd=$(readlink "$spec/initrd" 2>/dev/null) || return 0
    params=$(cat "$spec/kernel-params" 2>/dev/null || echo "")
    emit_nixos_one "$label" "$spec/init" "$kernel" "$initrd" "$params"
}

producer_nixos_rollback() {
    label="$1"; max="${2:-5}"
    [ -d "$NIX_PROFILES" ] || { warn "  $label: /nix not mounted, skipping"; return 0; }

    # rEFInd has no top-level submenu construct. We emit a HEADER menuentry
    # named "$label" that itself loads the current default (so pressing Enter
    # on it = same as Primary), and embed the rollback generations as
    # submenuentry children. Press F2 on this entry in rEFInd to see the
    # rollback list.

    sys=$(readlink -f "$NIX_PROFILES/system" 2>/dev/null) || return 0
    cur_kernel=$(readlink "$sys/kernel" 2>/dev/null) || return 0
    cur_initrd=$(readlink "$sys/initrd" 2>/dev/null) || return 0
    cur_params=$(cat "$sys/kernel-params" 2>/dev/null || echo "")
    cur_kboot=$(nix_to_boot_name "$cur_kernel")
    cur_iboot=$(nix_to_boot_name "$cur_initrd")

    cat <<EOF
menuentry "$label" {
    icon ${ICON_PATH}/os_nixos.png
    volume "boot"
    loader /kernels/$cur_kboot
    initrd /kernels/$cur_iboot
    options "init=$sys/init $cur_params"
EOF

    # Each rollback gen becomes a submenuentry (visible via F2 on parent)
    for link in $(ls -1 "$NIX_PROFILES" 2>/dev/null | grep '^system-[0-9]\+-link$' \
                  | sort -t- -k2 -n -r | head -n "$max"); do
        gen=$(echo "$link" | sed 's/^system-\([0-9]\+\)-link$/\1/')
        sys_path="$NIX_PROFILES/$link"
        gsys=$(readlink -f "$sys_path" 2>/dev/null) || continue
        [ -d "$gsys" ] || continue

        date=$(stat -c %y "$sys_path" 2>/dev/null | cut -d' ' -f1)
        gk=$(readlink "$gsys/kernel" 2>/dev/null) || continue
        gi=$(readlink "$gsys/initrd" 2>/dev/null) || continue
        gp=$(cat "$gsys/kernel-params" 2>/dev/null || echo "")
        gkboot=$(nix_to_boot_name "$gk")
        giboot=$(nix_to_boot_name "$gi")

        cat <<EOF
    submenuentry "Gen $gen ($date) — default" {
        loader /kernels/$gkboot
        initrd /kernels/$giboot
        add_options "init=$gsys/init $gp"
    }
EOF

        # specialisations under each gen
        if [ -d "$gsys/specialisation" ]; then
            for spec in "$gsys/specialisation"/*; do
                [ -d "$spec" ] || continue
                sname=$(basename "$spec")
                sk=$(readlink "$spec/kernel" 2>/dev/null) || continue
                si=$(readlink "$spec/initrd" 2>/dev/null) || continue
                sp=$(cat "$spec/kernel-params" 2>/dev/null || echo "")
                skboot=$(nix_to_boot_name "$sk")
                siboot=$(nix_to_boot_name "$si")
                cat <<EOF
    submenuentry "Gen $gen — $sname" {
        loader /kernels/$skboot
        initrd /kernels/$siboot
        add_options "init=$spec/init $sp"
    }
EOF
            done
        fi
    done

    cat <<EOF
}

EOF
}

producer_linux_partition() {
    label="$1"; from="$2"
    [ -n "$from" ] || { warn "  $label: missing 'from' field"; return 0; }
    enabled=$(jq -r ".grub.menu.$from.enabled // false" "$BOOT_JSON")
    [ "$enabled" = "true" ] || { warn "  $label: source grub.menu.$from disabled"; return 0; }
    uuid=$(jq -r ".grub.menu.$from.root_uuid" "$BOOT_JSON")
    kernel=$(jq -r ".grub.menu.$from.kernel" "$BOOT_JSON")
    initrd=$(jq -r ".grub.menu.$from.initrd" "$BOOT_JSON")
    opts=$(jq -r ".grub.menu.$from.options" "$BOOT_JSON")
    cat <<EOF
menuentry "$label" {
    icon ${ICON_PATH}/os_$from.png
    volume "$uuid"
    loader $kernel
    initrd $initrd
    options "root=UUID=$uuid $opts"
}

EOF
}

producer_usb_chainload() {
    label="$1"; from="$2"
    [ -n "$from" ] || { warn "  $label: missing 'from' field"; return 0; }
    # Find usb entry by id=$from
    entry=$(jq -c ".grub.menu.usb.entries[] | select(.id == \"$from\")" "$BOOT_JSON")
    [ -n "$entry" ] || { warn "  $label: no usb entry with id=$from"; return 0; }
    uuid=$(echo "$entry" | jq -r '.efi_uuid // ""')
    path=$(echo "$entry" | jq -r '.efi_path')
    [ -n "$uuid" ] || { warn "  $label: usb entry has no efi_uuid"; return 0; }
    cat <<EOF
menuentry "$label" {
    icon ${ICON_PATH}/vol_external.png
    volume "$uuid"
    loader $path
}

EOF
}

producer_windows_chainload() {
    label="$1"
    enabled=$(jq -r '.grub.menu.windows.enabled // false' "$BOOT_JSON")
    [ "$enabled" = "true" ] || return 0
    uuid=$(jq -r '.grub.menu.windows.efi_uuid' "$BOOT_JSON")
    path=$(jq -r '.grub.menu.windows.efi_path' "$BOOT_JSON")
    cat <<EOF
menuentry "$label" {
    icon ${ICON_PATH}/os_win.png
    volume "$uuid"
    loader $path
}

EOF
}

producer_refind_self() {
    label="$1"
    cat <<EOF
menuentry "$label" {
    icon ${ICON_PATH}/func_about.png
    volume "$ESP_UUID"
    loader /EFI/refind/refind_x64.efi
}

EOF
}

# ════════════════════════════════════════════════════════════════════════════
# RENDER
# ════════════════════════════════════════════════════════════════════════════

{
    cat <<EOF
# AUTO-GENERATED by aa_bootloader/src/gen/render-refind-conf.sh
# DO NOT EDIT — regenerated from src/boot.json
# Generated: $(date '+%Y-%m-%d %H:%M:%S UTC%z')
# Mode: $SCANFOR (autodetect off when scanfor=manual only)

timeout         $TIMEOUT
default_selection "$DEFAULT"
resolution      $RESOLUTION
use_graphics_for linux,windows
showtools       $SHOWTOOLS
scanfor         $SCANFOR

# Skip orphaned directories (left over from prior bootloaders)
EOF
    [ -n "$DONT_SCAN_DIRS" ] && echo "dont_scan_dirs   $DONT_SCAN_DIRS"

    # Theme include — declarative via .refind.install.theme.{enabled,name,theme_conf}
    THEME_ENABLED=$(jq -r '.refind.install.theme.enabled // false' "$BOOT_JSON")
    if [ "$THEME_ENABLED" = "true" ]; then
        THEME_NAME=$(jq -r '.refind.install.theme.name' "$BOOT_JSON")
        THEME_CONF=$(jq -r '.refind.install.theme.theme_conf // "theme.conf"' "$BOOT_JSON")
        echo ""
        echo "# Theme (declarative — vendored at src/vendored/refind-themes/$THEME_NAME/)"
        echo "include         themes/$THEME_NAME/$THEME_CONF"
    fi

    cat <<EOF

# ═══════════════════════════════════════════════════════════════════════════
# Top-level menu (order from boot.json refind.manual_stanzas.order)
# ═══════════════════════════════════════════════════════════════════════════

EOF

    # Iterate the order array, dispatch by producer
    n=$(jq '.refind.manual_stanzas.order | length' "$BOOT_JSON")
    i=0
    while [ "$i" -lt "$n" ]; do
        producer=$(jq -r ".refind.manual_stanzas.order[$i].producer" "$BOOT_JSON")
        label=$(jq -r ".refind.manual_stanzas.order[$i].label" "$BOOT_JSON")
        from=$(jq -r ".refind.manual_stanzas.order[$i].from // \"\"" "$BOOT_JSON")
        max=$(jq -r ".refind.manual_stanzas.order[$i].max // 5" "$BOOT_JSON")

        case "$producer" in
            nixos_primary)     producer_nixos_primary "$label" ;;
            nixos_rescue)      producer_nixos_rescue "$label" ;;
            nixos_safegfx)     producer_nixos_safegfx "$label" ;;
            nixos_rollback)    producer_nixos_rollback "$label" "$max" ;;
            linux_partition)   producer_linux_partition "$label" "$from" ;;
            usb_chainload)     producer_usb_chainload "$label" "$from" ;;
            windows_chainload) producer_windows_chainload "$label" ;;
            refind_self)       producer_refind_self "$label" ;;
            *)                 warn "Unknown producer: $producer (label: $label)" ;;
        esac
        i=$((i + 1))
    done

} > "$OUT"

log "Wrote: $OUT  ($(wc -l < "$OUT") lines, order=$n entries)"

# ═══════════════════════════════════════════════════════════════════════════
# THEME.CONF GENERATOR — overrides the upstream's bundled theme.conf with one
# whose paths/sizes/variant/font are all data-driven from boot.json. The
# vendored theme ships a default theme.conf that hardcodes the theme dir
# name as `themes/refind-theme-regular/...` — wrong for our deploy, where the
# engine renames the dir to `themes/<refind.install.theme.name>/`. Without
# this generator the include chain points at non-existent paths and rEFInd
# silently falls back to its built-in icons (the bug that left the menu
# looking unthemed AND with no labels). Always emit our own theme.conf.
# ═══════════════════════════════════════════════════════════════════════════
if [ "$THEME_ENABLED" = "true" ]; then
    THEME_VARIANT=$(jq -r '.refind.install.theme.variant // "dark"' "$BOOT_JSON")
    THEME_FONT=$(jq -r '.refind.install.theme.font // "source-code-pro-extralight-32"' "$BOOT_JSON")
    THEME_SHOW_LABEL=$(jq -r '.refind.install.theme.show_label // true' "$BOOT_JSON")
    THEME_BIG=$(echo "$THEME_ICON_SET" | cut -d- -f1)
    THEME_SMALL=$(echo "$THEME_ICON_SET" | cut -d- -f2)

    case "$THEME_VARIANT" in
        dark)  BG_FILE="bg_dark.png"
               SEL_BIG="selection_dark-big.png"
               SEL_SMALL="selection_dark-small.png" ;;
        *)     BG_FILE="bg.png"
               SEL_BIG="selection-big.png"
               SEL_SMALL="selection-small.png" ;;
    esac

    # hideui — never hides label unless explicitly disabled. Other entries
    # are taste/safety: drop hints (less clutter), keep arrows for clarity,
    # singleuser/safemode/hwtest are macOS-only so harmless to hide.
    HIDEUI="singleuser,hints,badges"
    [ "$THEME_SHOW_LABEL" = "false" ] && HIDEUI="$HIDEUI,label"

    THEME_CONF_OUT="$OUT_DIR/themes/$THEME_NAME/theme.conf"
    mkdir -p "$(dirname "$THEME_CONF_OUT")"
    cat > "$THEME_CONF_OUT" <<EOF
# ─────────────────────────────────────────────────────────────────────────
# AUTO-GENERATED by aa_bootloader/src/gen/render-refind-conf.sh
# Do NOT edit — overwritten on next \`build.sh generate\`.
# Source: refind.install.theme.* in src/boot.json.
# ─────────────────────────────────────────────────────────────────────────

hideui          $HIDEUI

icons_dir       themes/$THEME_NAME/icons/$THEME_ICON_SET
big_icon_size   $THEME_BIG
small_icon_size $THEME_SMALL

banner          themes/$THEME_NAME/icons/$THEME_ICON_SET/$BG_FILE
banner_scale    fillscreen

selection_big   themes/$THEME_NAME/icons/$THEME_ICON_SET/$SEL_BIG
selection_small themes/$THEME_NAME/icons/$THEME_ICON_SET/$SEL_SMALL

font            themes/$THEME_NAME/fonts/$THEME_FONT.png
EOF
    log "Wrote: $THEME_CONF_OUT  (theme=$THEME_NAME, set=$THEME_ICON_SET, variant=$THEME_VARIANT, label=$THEME_SHOW_LABEL)"
fi
