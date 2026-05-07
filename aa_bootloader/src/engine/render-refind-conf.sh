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
#   nixos_primary        current /nix/var/nix/profiles/system → top-level menuentry
#   nixos_specialisation reads grub.menu.nixos.specialisations[<from>] and
#                        emits a menuentry for /nix/var/nix/profiles/system/
#                        specialisation/<from>/ — generic; works for any
#                        specialisation name declared in the host flake
#                        (rescue-current-gen, rescue-native-install,
#                        safe-graphics, …)
#   nixos_rollback       submenu with last N gens (default + each specialisation)
#   linux_partition   reads grub.menu.<from> for kernel/initrd/uuid/options
#   usb_chainload     reads grub.menu.usb.entries[] where id == <from>
#   windows_chainload reads grub.menu.windows
#   efi_chainload     reads grub.menu.<from>.{efi_uuid,efi_path,icon} — chains
#                     a FAT-ESP-resident grubx64.efi (used for Kali/Debian
#                     because rEFInd's ext4 driver mishandles their /vmlinuz
#                     symlinks; GRUB then boots them via its richer ext4 mod)
#   refind_self       chainloads /EFI/refind/refind_x64.efi (config reload)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# shellcheck source=lib/log.sh
. "$ROOT_DIR/src/engine/lib/log.sh"
# shellcheck source=lib/json.sh
. "$ROOT_DIR/src/engine/lib/json.sh"

BOOT_JSON="$ROOT_DIR/src/boot.json"
# DO NOT default to $NIX_PROFILES — NixOS exports that as a space-separated
# search list of USER profile dirs, not the system profiles directory we need.
# Use the canonical system path directly. NIXOS_SYSTEM_PROFILES is a separate
# override knob for unusual layouts (e.g. /mnt/nixos when chrooted).
NIX_PROFILES="${NIXOS_SYSTEM_PROFILES:-/nix/var/nix/profiles}"
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
# Optional UI knobs (data-driven; emit only if declared).
TOOLS_DIR=$(jq -r '.refind.install.tools_dir // ""' "$BOOT_JSON")
ENABLE_TOUCH=$(jq -r '.refind.ui.enable_touch // false' "$BOOT_JSON")
ENABLE_MOUSE=$(jq -r '.refind.ui.enable_mouse // false' "$BOOT_JSON")
MOUSE_SIZE=$(jq -r '.refind.ui.mouse_size // ""' "$BOOT_JSON")
ESP_UUID=$(jq -r '.uefi.esp.uuid' "$BOOT_JSON")

# ── Theme path resolution (data-driven, FIRE RULE 4) ──────────────────────
# Producers must NOT hardcode /EFI/refind/icons/. Compute the theme-icons
# base path once here and let every emit_* / producer_* use $ICON_PATH.
# Falls back to the legacy /EFI/refind/icons/ when no theme is enabled.
#
# Two theme layouts supported, both selected by data:
#  (a) Munlik 'regular' style: themes/<name>/icons/<icon_set>/ + fonts/<font>.png
#      → declared via theme.icon_set ("256-96") + theme.variant + theme.font
#  (b) Explicit paths (Catppuccin and others):
#      → declared via theme.icons_path / banner_path / selection_*_path / font_path
#
# Explicit paths win when present. This keeps regular-style themes terse
# and lets new themes ship arbitrary directory layouts without engine edits.
THEME_ENABLED=$(jq -r '.refind.install.theme.enabled // false' "$BOOT_JSON")
if [ "$THEME_ENABLED" = "true" ]; then
    THEME_NAME=$(jq -r '.refind.install.theme.name' "$BOOT_JSON")
    THEME_ICON_SET=$(jq -r '.refind.install.theme.icon_set // ""' "$BOOT_JSON")
    EXPLICIT_ICONS=$(jq -r '.refind.install.theme.icons_path // ""' "$BOOT_JSON")
    if [ -n "$EXPLICIT_ICONS" ]; then
        ICON_PATH="$EXPLICIT_ICONS"
    elif [ -n "$THEME_ICON_SET" ]; then
        ICON_PATH="themes/${THEME_NAME}/icons/${THEME_ICON_SET}"
    else
        ICON_PATH="themes/${THEME_NAME}/icons"
    fi
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
    label="$1"; icon_override="$2"
    [ -d "$NIX_PROFILES" ] || { warn "  $label: /nix not mounted, skipping"; return 0; }
    sys=$(readlink -f "$NIX_PROFILES/system" 2>/dev/null) || return 0
    [ -d "$sys" ] || return 0
    kernel=$(readlink "$sys/kernel" 2>/dev/null) || return 0
    initrd=$(readlink "$sys/initrd" 2>/dev/null) || return 0
    params=$(cat "$sys/kernel-params" 2>/dev/null || echo "")
    icon=""
    [ -n "$icon_override" ] && icon="${ICON_PATH}/${icon_override}.png"
    emit_nixos_one "$label" "$sys/init" "$kernel" "$initrd" "$params" "$icon"
}

# Generic NixOS specialisation producer. Reads the specialisation NAME from
# the manual_stanzas entry's 'from' field and looks it up under
# /nix/var/nix/profiles/system/specialisation/<name>/. Adding a new
# specialisation is a 2-line edit (a new module + an order entry) — no
# engine code change. Validates against .grub.menu.nixos.specialisations
# in boot.json so typos in 'from' are caught at render time.
#
# FIRE RULE 4: data-driven. Replaces the per-specialisation hardcoded
# producer_nixos_rescue and producer_nixos_safegfx that previously
# hardcoded directory names — and got it wrong (they hardcoded 'rescue'
# but the actual NixOS dir is 'rescue-current-gen', so producer_nixos_rescue
# silently skipped every render).
producer_nixos_specialisation() {
    label="$1"; from="$2"; icon_override="$3"
    [ -n "$from" ] || { warn "  $label: missing 'from' field"; return 0; }
    [ -d "$NIX_PROFILES" ] || { warn "  $label: /nix not mounted, skipping"; return 0; }

    # Cross-check against the declared specialisation list — catches typos
    # before they silently disappear into "spec dir not found".
    declared=$(jq -r --arg n "$from" '.grub.menu.nixos.specialisations[]? | select(. == $n)' "$BOOT_JSON")
    if [ -z "$declared" ]; then
        warn "  $label: 'from=$from' not in .grub.menu.nixos.specialisations (boot.json)"
        return 0
    fi

    sys=$(readlink -f "$NIX_PROFILES/system" 2>/dev/null) || return 0
    spec="$sys/specialisation/$from"
    [ -d "$spec" ] || { warn "  $label: specialisation '$from' not materialised on disk yet (run nixos-rebuild switch)"; return 0; }
    kernel=$(readlink "$spec/kernel" 2>/dev/null) || return 0
    initrd=$(readlink "$spec/initrd" 2>/dev/null) || return 0
    params=$(cat "$spec/kernel-params" 2>/dev/null || echo "")
    icon=""
    [ -n "$icon_override" ] && icon="${ICON_PATH}/${icon_override}.png"
    emit_nixos_one "$label" "$spec/init" "$kernel" "$initrd" "$params" "$icon"
}

producer_nixos_rollback() {
    label="$1"; max="${2:-5}"; icon_override="$3"
    [ -d "$NIX_PROFILES" ] || { warn "  $label: /nix not mounted, skipping"; return 0; }
    rb_icon="${ICON_PATH}/os_nixos.png"
    [ -n "$icon_override" ] && rb_icon="${ICON_PATH}/${icon_override}.png"

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
    icon $rb_icon
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
    label="$1"; from="$2"; icon_override="$3"
    [ -n "$from" ] || { warn "  $label: missing 'from' field"; return 0; }
    enabled=$(jq -r ".grub.menu.$from.enabled // false" "$BOOT_JSON")
    [ "$enabled" = "true" ] || { warn "  $label: source grub.menu.$from disabled"; return 0; }
    uuid=$(jq -r ".grub.menu.$from.root_uuid" "$BOOT_JSON")
    kernel=$(jq -r ".grub.menu.$from.kernel" "$BOOT_JSON")
    initrd=$(jq -r ".grub.menu.$from.initrd" "$BOOT_JSON")
    opts=$(jq -r ".grub.menu.$from.options" "$BOOT_JSON")
    icon="${icon_override:-os_$from}"
    cat <<EOF
menuentry "$label" {
    icon ${ICON_PATH}/${icon}.png
    volume "$uuid"
    loader $kernel
    initrd $initrd
    options "root=UUID=$uuid $opts"
}

EOF
}

producer_usb_chainload() {
    label="$1"; from="$2"; icon_override="$3"
    [ -n "$from" ] || { warn "  $label: missing 'from' field"; return 0; }
    entry=$(jq -c ".grub.menu.usb.entries[] | select(.id == \"$from\")" "$BOOT_JSON")
    [ -n "$entry" ] || { warn "  $label: no usb entry with id=$from"; return 0; }
    uuid=$(echo "$entry" | jq -r '.efi_uuid // ""')
    path=$(echo "$entry" | jq -r '.efi_path')
    icon="${icon_override:-vol_external}"
    [ -n "$uuid" ] || { warn "  $label: usb entry has no efi_uuid"; return 0; }
    cat <<EOF
menuentry "$label" {
    icon ${ICON_PATH}/${icon}.png
    volume "$uuid"
    loader $path
}

EOF
}

producer_windows_chainload() {
    label="$1"; icon_override="$2"
    enabled=$(jq -r '.grub.menu.windows.enabled // false' "$BOOT_JSON")
    [ "$enabled" = "true" ] || return 0
    uuid=$(jq -r '.grub.menu.windows.efi_uuid' "$BOOT_JSON")
    path=$(jq -r '.grub.menu.windows.efi_path' "$BOOT_JSON")
    icon="${icon_override:-os_win}"
    cat <<EOF
menuentry "$label" {
    icon ${ICON_PATH}/${icon}.png
    volume "$uuid"
    loader $path
}

EOF
}

# Generic FAT-ESP-resident EFI binary chainloader. Used when an OS lives on an
# ext4 partition whose kernels rEFInd's bundled ext4_x64.efi driver can't
# reliably load (relative /vmlinuz symlinks at the FS root → "Invalid Loader
# File!"), so rEFInd hands off to a grubx64.efi already on the FAT ESP — that
# GRUB then boots the OS via its richer ext4 driver. Also used for the
# GRUB-fallback button that chainloads our co-installed GRUB.
# Reads grub.menu.<from>: enabled, efi_uuid, efi_path, icon (optional).
producer_efi_chainload() {
    label="$1"; from="$2"; icon_override="$3"
    [ -n "$from" ] || { warn "  $label: missing 'from' field"; return 0; }
    enabled=$(jq -r ".grub.menu.$from.enabled // false" "$BOOT_JSON")
    [ "$enabled" = "true" ] || { warn "  $label: source grub.menu.$from disabled"; return 0; }
    uuid=$(jq -r ".grub.menu.$from.efi_uuid // \"\"" "$BOOT_JSON")
    path=$(jq -r ".grub.menu.$from.efi_path // \"\"" "$BOOT_JSON")
    # Priority: per-stanza icon override (manual_stanzas.order) >
    #           grub.menu.<from>.icon > "os_<from>" default
    if [ -n "$icon_override" ]; then
        icon="$icon_override"
    else
        icon=$(jq -r ".grub.menu.$from.icon // \"os_$from\"" "$BOOT_JSON")
    fi
    [ -n "$uuid" ] || { warn "  $label: grub.menu.$from missing efi_uuid"; return 0; }
    [ -n "$path" ] || { warn "  $label: grub.menu.$from missing efi_path"; return 0; }
    cat <<EOF
menuentry "$label" {
    icon ${ICON_PATH}/${icon}.png
    volume "$uuid"
    loader $path
}

EOF
}

producer_refind_self() {
    label="$1"; icon_override="$2"
    icon="${icon_override:-os_refind}"
    cat <<EOF
menuentry "$label" {
    icon ${ICON_PATH}/${icon}.png
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
    # tools_dir: extends rEFInd's default tool-binary search list (which is
    # /EFI/refind/, /EFI/tools/, /EFI/) with the named subdir relative to
    # rEFInd's install path. Required so showtools "shell"/"memtest" find
    # binaries in /EFI/refind/tools/ instead of silently dropping the button.
    [ -n "$TOOLS_DIR" ] && echo "tools_dir        $TOOLS_DIR"
    # Surface Pro 8 touchscreen + optional mouse pointer.
    [ "$ENABLE_TOUCH" = "true" ] && echo "enable_touch"
    [ "$ENABLE_MOUSE" = "true" ] && echo "enable_mouse"
    [ -n "$MOUSE_SIZE" ] && echo "mouse_size       $MOUSE_SIZE"

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
        # Per-stanza icon override (FIRE 4: data-driven from boot.json).
        # Empty string means "use producer default". Each producer threads it
        # through to its emit_* function.
        icon=$(jq -r ".refind.manual_stanzas.order[$i].icon // \"\"" "$BOOT_JSON")

        case "$producer" in
            nixos_primary)        producer_nixos_primary "$label" "$icon" ;;
            nixos_specialisation) producer_nixos_specialisation "$label" "$from" "$icon" ;;
            nixos_rollback)       producer_nixos_rollback "$label" "$max" "$icon" ;;
            linux_partition)      producer_linux_partition "$label" "$from" "$icon" ;;
            usb_chainload)        producer_usb_chainload "$label" "$from" "$icon" ;;
            windows_chainload)    producer_windows_chainload "$label" "$icon" ;;
            efi_chainload)        producer_efi_chainload "$label" "$from" "$icon" ;;
            refind_self)          producer_refind_self "$label" "$icon" ;;
            *)                    warn "Unknown producer: $producer (label: $label)" ;;
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
    THEME_FONT=$(jq -r '.refind.install.theme.font // ""' "$BOOT_JSON")
    THEME_SHOW_LABEL=$(jq -r '.refind.install.theme.show_label // true' "$BOOT_JSON")

    # Explicit-path mode (Catppuccin and other arbitrary layouts) takes priority.
    # Non-empty fields win; otherwise we derive Munlik 'regular' style paths
    # from icon_set + variant.
    EX_BANNER=$(jq -r '.refind.install.theme.banner_path // ""' "$BOOT_JSON")
    EX_SEL_BIG=$(jq -r '.refind.install.theme.selection_big_path // ""' "$BOOT_JSON")
    EX_SEL_SMALL=$(jq -r '.refind.install.theme.selection_small_path // ""' "$BOOT_JSON")
    EX_FONT=$(jq -r '.refind.install.theme.font_path // ""' "$BOOT_JSON")
    EX_BIG_SIZE=$(jq -r '.refind.install.theme.big_icon_size // ""' "$BOOT_JSON")
    EX_SMALL_SIZE=$(jq -r '.refind.install.theme.small_icon_size // ""' "$BOOT_JSON")

    if [ -n "$THEME_ICON_SET" ]; then
        DERIVED_BIG=$(echo "$THEME_ICON_SET" | cut -d- -f1)
        DERIVED_SMALL=$(echo "$THEME_ICON_SET" | cut -d- -f2)
        case "$THEME_VARIANT" in
            dark)  BG_FILE="bg_dark.png"
                   SEL_BIG_FILE="selection_dark-big.png"
                   SEL_SMALL_FILE="selection_dark-small.png" ;;
            *)     BG_FILE="bg.png"
                   SEL_BIG_FILE="selection-big.png"
                   SEL_SMALL_FILE="selection-small.png" ;;
        esac
        DERIVED_BANNER="themes/$THEME_NAME/icons/$THEME_ICON_SET/$BG_FILE"
        DERIVED_SEL_BIG="themes/$THEME_NAME/icons/$THEME_ICON_SET/$SEL_BIG_FILE"
        DERIVED_SEL_SMALL="themes/$THEME_NAME/icons/$THEME_ICON_SET/$SEL_SMALL_FILE"
    else
        DERIVED_BIG=""; DERIVED_SMALL=""
        DERIVED_BANNER=""; DERIVED_SEL_BIG=""; DERIVED_SEL_SMALL=""
    fi

    BIG_SIZE="${EX_BIG_SIZE:-$DERIVED_BIG}"
    SMALL_SIZE="${EX_SMALL_SIZE:-$DERIVED_SMALL}"
    BANNER_PATH="${EX_BANNER:-$DERIVED_BANNER}"
    SEL_BIG_PATH="${EX_SEL_BIG:-$DERIVED_SEL_BIG}"
    SEL_SMALL_PATH="${EX_SEL_SMALL:-$DERIVED_SEL_SMALL}"
    if [ -n "$EX_FONT" ]; then
        FONT_PATH="$EX_FONT"
    elif [ -n "$THEME_FONT" ]; then
        FONT_PATH="themes/$THEME_NAME/fonts/$THEME_FONT.png"
    else
        FONT_PATH=""
    fi

    # hideui — never hides label unless explicitly disabled. Other entries
    # are taste/safety: drop hints (less clutter), singleuser/safemode/hwtest
    # are macOS-only so harmless to hide.
    HIDEUI="singleuser,hints,badges"
    [ "$THEME_SHOW_LABEL" = "false" ] && HIDEUI="$HIDEUI,label"

    THEME_CONF_OUT="$OUT_DIR/themes/$THEME_NAME/theme.conf"
    mkdir -p "$(dirname "$THEME_CONF_OUT")"
    {
        cat <<EOF
# ─────────────────────────────────────────────────────────────────────────
# AUTO-GENERATED by aa_bootloader/src/engine/render-refind-conf.sh
# Do NOT edit — overwritten on next \`build.sh build-refind\`.
# Source: refind.install.theme.* in src/boot.json.
# ─────────────────────────────────────────────────────────────────────────

hideui          $HIDEUI

icons_dir       $ICON_PATH
EOF
        [ -n "$BIG_SIZE" ]   && echo "big_icon_size   $BIG_SIZE"
        [ -n "$SMALL_SIZE" ] && echo "small_icon_size $SMALL_SIZE"
        echo
        if [ -n "$BANNER_PATH" ]; then
            echo "banner          $BANNER_PATH"
            echo "banner_scale    fillscreen"
            echo
        fi
        [ -n "$SEL_BIG_PATH" ]   && echo "selection_big   $SEL_BIG_PATH"
        [ -n "$SEL_SMALL_PATH" ] && echo "selection_small $SEL_SMALL_PATH"
        if [ -n "$FONT_PATH" ]; then
            echo
            echo "font            $FONT_PATH"
        fi
    } > "$THEME_CONF_OUT"
    log "Wrote: $THEME_CONF_OUT  (theme=$THEME_NAME, variant=$THEME_VARIANT, label=$THEME_SHOW_LABEL, font=${FONT_PATH:-<rEFInd default>})"
fi
