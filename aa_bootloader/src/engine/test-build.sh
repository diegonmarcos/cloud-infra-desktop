#!/bin/sh
# test-build.sh — declarative tests over dist/ output (FIRE RULE 5)
#
# Run AFTER `build.sh build-refind` + `build-grub`. All tests are pure file
# inspection over dist/ — no live system, no sudo, no /boot writes.
#
# Test groups:
#   T1  refind.conf has the right menuentry shape
#   T2  every chainload `loader` path resolves in dist/
#   T3  every menuentry `icon` PNG exists in dist/
#   T4  generated theme.conf paths all resolve in dist/
#   T5  every menuentry label is ASCII-only (no UTF-8 ?? glyphs)
#   T6  grub.cfg renders both Kali and Debian (regression: emit_debian gap)
#   T7  NVRAM entry path matches grub.install.efi_install_dir (data consistency)
#
# Exit non-zero if any test fails.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# shellcheck source=lib/log.sh
. "$ROOT_DIR/src/engine/lib/log.sh"

BOOT_JSON="$ROOT_DIR/src/boot.json"
DIST="$ROOT_DIR/dist"
ESP="$DIST/boot/efi"
REFIND_CONF="$ESP/EFI/refind/refind.conf"
THEME_NAME=$(jq -r '.refind.install.theme.name // ""' "$BOOT_JSON")
THEME_CONF="$ESP/EFI/refind/themes/$THEME_NAME/theme.conf"
GRUB_CFG="$DIST/boot/grub/grub.cfg"

PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
hdr()  { echo; echo "── $1 ──"; }

# ── Pre-flight ─────────────────────────────────────────────────────────────
[ -f "$REFIND_CONF" ] || { error "Missing $REFIND_CONF — run build-refind first"; exit 2; }
[ -f "$GRUB_CFG"    ] || { error "Missing $GRUB_CFG — run build-grub first"; exit 2; }

# ── T1 refind.conf shape ──────────────────────────────────────────────────
hdr "T1 refind.conf menuentry shape"
expected_order=$(jq -r '.refind.manual_stanzas.order[].label' "$BOOT_JSON")
expected_count=$(echo "$expected_order" | wc -l)
got_count=$(grep -c '^menuentry "' "$REFIND_CONF" || echo 0)
# Some NixOS producers skip silently when /nix isn't mounted, so got_count may
# be lower than expected_count in non-NixOS environments. Test that NON-NIXOS
# entries are all present.
non_nixos_expected=$(echo "$expected_order" | grep -v '^NixOS' || true)
all_present=true
echo "$non_nixos_expected" | while IFS= read -r label; do
    [ -z "$label" ] && continue
    if grep -qF "menuentry \"$label\"" "$REFIND_CONF"; then
        echo "  ✓ $label"
    else
        echo "  ✗ $label MISSING"
        exit 1
    fi
done && pass "all non-NixOS menuentries present ($got_count rendered)" || fail "some non-NixOS menuentries missing"

# ── T2 every loader path resolves in dist/ ────────────────────────────────
# Two volumes: ESP at dist/boot/efi/ and /boot at dist/boot/. Loader paths
# starting with /kernels/ live on /boot (the NixOS kernels staging dir),
# /EFI/* paths live on the ESP, /EFI/BOOT/BOOTX64.EFI is on a foreign USB
# (skipped). Mirrors verify-boot-ready's T-C logic so the dist tester and
# the live tester agree.
hdr "T2 loader paths exist in dist/"
BOOT_DIST="$DIST/boot"
grep -E '^\s+loader ' "$REFIND_CONF" | awk '{print $2}' | sort -u | while IFS= read -r path; do
    rel_path=${path#/}
    case "$path" in
        /kernels/*)
            if [ -f "$BOOT_DIST/$rel_path" ]; then
                pass "loader $path → $BOOT_DIST/$rel_path"
            else
                fail "loader $path NOT FOUND at $BOOT_DIST/$rel_path"
            fi
            ;;
        /EFI/BOOT/BOOTX64.EFI)
            pass "loader $path (lives on external USB volume — not in our dist/)"
            ;;
        /EFI/*)
            if [ -f "$ESP/$rel_path" ]; then
                pass "loader $path → $ESP/$rel_path"
            else
                fail "loader $path NOT FOUND at $ESP/$rel_path"
            fi
            ;;
        *)
            fail "loader $path — unrecognised path style"
            ;;
    esac
done

# ── T3 menuentry icon PNGs exist in dist/ ──────────────────────────────────
hdr "T3 menuentry icon PNGs exist in dist/"
grep -E '^\s+icon ' "$REFIND_CONF" | awk '{print $2}' | sort -u | while IFS= read -r icon; do
    abs="$ESP/EFI/refind/$icon"
    if [ -f "$abs" ]; then
        pass "icon $icon"
    else
        fail "icon $icon NOT FOUND at $abs"
    fi
done

# ── T4 generated theme.conf paths resolve ──────────────────────────────────
hdr "T4 theme.conf paths resolve in dist/"
if [ -f "$THEME_CONF" ]; then
    # Each path-bearing directive: icons_dir, banner, selection_big,
    # selection_small, font. icons_dir is a dir; rest are files.
    while IFS= read -r line; do
        case "$line" in
            'icons_dir'*)
                p=$(echo "$line" | awk '{print $2}')
                [ -d "$ESP/EFI/refind/$p" ] && pass "icons_dir $p (dir exists)" || fail "icons_dir $p missing"
                ;;
            'banner '*|'selection_big'*|'selection_small'*|'font '*)
                directive=$(echo "$line" | awk '{print $1}')
                p=$(echo "$line" | awk '{print $2}')
                [ -f "$ESP/EFI/refind/$p" ] && pass "$directive $p" || fail "$directive $p missing"
                ;;
        esac
    done < "$THEME_CONF"
else
    pass "(no theme enabled — skipping T4)"
fi

# ── T5 ASCII-only labels (no UTF-8 ?? glyphs) ──────────────────────────────
hdr "T5 menuentry labels are ASCII-only"
grep -E '^menuentry "' "$REFIND_CONF" | sed 's/^menuentry "\([^"]*\)" {.*/\1/' | while IFS= read -r label; do
    # Strip every printable-ASCII character (0x20–0x7E) and check for residue.
    # POSIX-portable: tr -d '\040-\176' deletes printable ASCII, leaving only
    # non-printable / non-ASCII bytes (which would render as ?? in rEFInd).
    residue=$(printf '%s' "$label" | LC_ALL=C tr -d '\040-\176' | wc -c)
    if [ "$residue" = "0" ]; then
        pass "ASCII label: $label"
    else
        fail "non-ASCII in label: '$label' ($residue non-ASCII bytes)"
    fi
done

# ── T6 grub.cfg has Kali AND Debian (regression: emit_debian gap) ──────────
hdr "T6 grub.cfg has all linux_order entries"
for key in $(jq -r '.grub.linux_order[]?' "$BOOT_JSON"); do
    label=$(jq -r ".grub.menu.$key.label" "$BOOT_JSON")
    if grep -qF "menuentry \"$label\"" "$GRUB_CFG"; then
        pass "grub.cfg has '$label' (key=$key)"
    else
        fail "grub.cfg MISSING '$label' (key=$key) — emit_linux_partition didn't fire"
    fi
done

# ── T8 every NixOS specialisation has a refind menuentry ──────────────────
# Regression test for the producer_nixos_rescue bug: the old code hardcoded
# specialisation name 'rescue', but NixOS materialises specialisations under
# their declared names (rescue-current-gen, rescue-native-install, …). The
# new generic producer_nixos_specialisation reads the name from boot.json's
# manual_stanzas.order[*].from. Test that each declared specialisation in
# .grub.menu.nixos.specialisations corresponds to (a) a manual_stanzas
# entry that uses it, (b) a rendered menuentry in refind.conf — but only
# when /nix is mounted (skip otherwise).
hdr "T8 NixOS specialisations render in refind.conf"
NIX_PROFILES_DIR="${NIXOS_SYSTEM_PROFILES:-/nix/var/nix/profiles}"
if [ ! -d "$NIX_PROFILES_DIR" ]; then
    pass "(no /nix/var/nix/profiles — skipping; would test on real NixOS host)"
else
    for name in $(jq -r '.grub.menu.nixos.specialisations[]?' "$BOOT_JSON"); do
        # Find the manual_stanzas entry that uses this specialisation as 'from'.
        label=$(jq -r --arg n "$name" '.refind.manual_stanzas.order[] | select(.producer == "nixos_specialisation" and .from == $n) | .label' "$BOOT_JSON" | head -1)
        if [ -z "$label" ]; then
            fail "specialisation '$name' has no nixos_specialisation entry in refind.manual_stanzas.order"
            continue
        fi
        if grep -qF "menuentry \"$label\"" "$REFIND_CONF"; then
            pass "specialisation '$name' → menuentry '$label'"
        else
            # Specialisation declared and stanza exists, but renderer skipped
            # — likely because the specialisation isn't materialised on disk.
            if [ -d "$NIX_PROFILES_DIR/system/specialisation/$name" ]; then
                fail "specialisation '$name' is on disk but '$label' NOT in refind.conf — engine bug"
            else
                pass "(specialisation '$name' declared but not materialised on disk — skipping render check)"
            fi
        fi
    done
fi

# ── T10 showtools entries are backed by binary or built-in ───────────────
# Regression test for the silent-no-op-button bug. Every keyword in
# refind.ui.showtools must either be one of rEFInd's built-in tools (which
# always render) OR have an EFI binary on the ESP that rEFInd can find via
# its default search paths or theme.tools_dir.
hdr "T10 showtools entries are backed by binary or built-in"
# Built-in tools: rendered without an external EFI binary.
BUILTIN_TOOLS="about bootorder hidden_tags csr_rotate exit firmware reboot shutdown install"
# External-binary tools: showtools keyword → expected EFI binary basename.
declare_external() {
    case "$1" in
        shell)             echo "shellx64.efi" ;;
        memtest|memtest86) echo "memtest86.efi" ;;
        netboot)           echo "ipxe.efi" ;;
        gdisk)             echo "gdisk_x64.efi" ;;
        gptsync)           echo "gptsync_x64.efi" ;;
        mok_tool)          echo "MokManager.efi" ;;
        fwupdate)          echo "fwupdx64.efi" ;;
        apple_recovery)    echo "" ;;  # auto-detected on Mac
        windows_recovery)  echo "" ;;  # auto-detected on Win recovery
        *)                 echo "" ;;
    esac
}

TOOLS_DIR=$(jq -r '.refind.install.tools_dir // ""' "$BOOT_JSON")
SEARCH_DIRS="$ESP/EFI/refind"
[ -n "$TOOLS_DIR" ] && SEARCH_DIRS="$SEARCH_DIRS $ESP/EFI/refind/$TOOLS_DIR"
SEARCH_DIRS="$SEARCH_DIRS $ESP/EFI/tools $ESP/EFI"

for tool in $(jq -r '.refind.ui.showtools[]?' "$BOOT_JSON"); do
    if echo " $BUILTIN_TOOLS " | grep -q " $tool "; then
        pass "showtools '$tool' is built-in (no binary required)"
        continue
    fi
    bin=$(declare_external "$tool")
    if [ -z "$bin" ]; then
        pass "showtools '$tool' (auto-detected by rEFInd at runtime)"
        continue
    fi
    found=""
    for dir in $SEARCH_DIRS; do
        [ -f "$dir/$bin" ] && { found="$dir/$bin"; break; }
    done
    if [ -n "$found" ]; then
        pass "showtools '$tool' → $bin found at $found"
    else
        fail "showtools '$tool' needs $bin but it's NOT in any search path: $SEARCH_DIRS"
    fi
done

# ── T9 grubx64.efi has the boot UUID baked in ────────────────────────────
# Regression test for the rescue-shell-on-boot bug. grubx64.efi must contain
# the ext4 /boot partition's UUID in its embedded pre-config, otherwise GRUB
# starts on the FAT ESP, can't find its grub.cfg there, and drops to the
# rescue prompt. Walks the binary with `strings` and looks for the UUID.
hdr "T9 grubx64.efi has embedded boot UUID"
GRUB_DIR_REL=$(jq -r '.grub.install.efi_install_dir' "$BOOT_JSON")
GRUB_BIN_DIST="$ESP/EFI${GRUB_DIR_REL#/EFI}/grubx64.efi"
[ -f "$GRUB_BIN_DIST" ] || GRUB_BIN_DIST="$ESP$GRUB_DIR_REL/grubx64.efi"
BOOT_UUID=$(jq -r '.uefi.boot.uuid' "$BOOT_JSON")
if [ -f "$GRUB_BIN_DIST" ]; then
    if strings "$GRUB_BIN_DIST" | grep -qF "$BOOT_UUID"; then
        pass "grubx64.efi contains boot UUID '$BOOT_UUID' (embedded prefix search)"
    else
        fail "grubx64.efi MISSING boot UUID '$BOOT_UUID' — would drop to rescue shell on boot"
    fi
    if strings "$GRUB_BIN_DIST" | grep -q 'search.fs_uuid'; then
        pass "grubx64.efi contains search.fs_uuid pre-config command"
    else
        fail "grubx64.efi MISSING search.fs_uuid — embedded config not baked in"
    fi
else
    fail "grubx64.efi not found at $GRUB_BIN_DIST"
fi

# ── T7 NVRAM entry path matches grub.install.efi_install_dir ───────────────
hdr "T7 NVRAM ↔ grub.install consistency"
# jq emits the JSON-parsed string value with single backslashes (escapes
# resolved). For input "\\EFI\\bootloader\\grubx64.efi" we get \EFI\bootloader\grubx64.efi.
GRUB_DIR=$(jq -r '.grub.install.efi_install_dir' "$BOOT_JSON")    # /EFI/bootloader
GRUB_DIR_BACKSLASH=$(printf '%s' "$GRUB_DIR" | tr '/' '\\')        # \EFI\bootloader
EXPECTED_PATH="${GRUB_DIR_BACKSLASH}\\grubx64.efi"
DEFAULT_NVRAM_PATH=$(jq -r '.uefi.nvram.entries[]? | select(.default == true) | .path' "$BOOT_JSON")
if [ "$DEFAULT_NVRAM_PATH" = "$EXPECTED_PATH" ]; then
    pass "default NVRAM entry path '$DEFAULT_NVRAM_PATH' matches grub.install.efi_install_dir"
else
    fail "default NVRAM '$DEFAULT_NVRAM_PATH' != expected '$EXPECTED_PATH'"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
if [ "$FAIL" = "0" ]; then
    log "test-build: $PASS passed, 0 failed"
    exit 0
else
    error "test-build: $PASS passed, $FAIL FAILED"
    exit 1
fi
