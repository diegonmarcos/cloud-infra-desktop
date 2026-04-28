#!/usr/bin/env bash
# test-baloo-excludes.sh — verify the declarative baloofilerc renders the
# extensive exclude rules + the dev-machine subtrees we never want indexed.
#
# Symptom: KDE Baloo's default config indexes every file under $HOME except
# a tiny baked-in list. On this dev box that means baloo_file_extractor
# sustains 40-50% CPU forever trying to index ~/git (rust target/, cargo
# cache, node_modules, container layers, VM images, nix imports). Combined
# with btrfs-on-LUKS the load avg jumps to 15+ while no useful work is
# happening.
#
# Two-layer assertion:
#   1. SOURCE (plasma.nix) carries every required exclude pattern. This
#      is the truth — what home-manager will deploy on next switch.
#   2. LIVE (~/.config/baloofilerc) matches source if a switch has been
#      done; otherwise prints a warning telling the user to run
#      build.sh switch and balooctl6 purge.

set -euo pipefail

SRC="${BASH_SOURCE[0]%/*}/plasma.nix"
LIVE="$HOME/.config/baloofilerc"
FAILS=0

[ -f "$SRC" ] || { echo "✗ source $SRC missing"; exit 1; }
echo "✓ source plasma.nix found at $SRC"

# 1. SOURCE-LEVEL ASSERTIONS — what home-manager will render
section() {
    awk '/xdg.configFile."baloofilerc"\.text = ..$/,/^  ..;/' "$SRC"
}

REQUIRED_FOLDERS=(
    '$HOME/git'         '$HOME/.cargo'    '$HOME/.rustup'
    '$HOME/.npm'        '$HOME/.docker'   '$HOME/.podman'
    '$HOME/.gradle'     '$HOME/.m2'       '$HOME/.terraform.d'
    '$HOME/.nix-profile'
)
REQUIRED_EXTENSIONS=(
    'target'   'release'  'debug'
    '*.rlib'   '*.rmeta'  '*.crate'
    '*.iso'    '*.qcow2'  '*.vmdk'
    '*.tar.zst' '*.AppImage'
)

if ! grep -qE '^[[:space:]]*exclude folders\[\$e\]=' "$SRC"; then
    echo "✗ SOURCE: exclude folders[\$e]= missing — \$HOME won't expand"
    FAILS=$((FAILS + 1))
else
    echo "✓ SOURCE: exclude folders[\$e]= present (KConfig will expand \$HOME)"
fi

for dir in "${REQUIRED_FOLDERS[@]}"; do
    if section | grep -qF "$dir"; then
        echo "✓ SOURCE: folder excluded — $dir"
    else
        echo "✗ SOURCE: folder NOT excluded — $dir"
        FAILS=$((FAILS + 1))
    fi
done

for ext in "${REQUIRED_EXTENSIONS[@]}"; do
    if section | grep -qF ",${ext}," || section | grep -qF "=${ext},"; then
        echo "✓ SOURCE: extension excluded — $ext"
    else
        echo "✗ SOURCE: extension NOT excluded — $ext"
        FAILS=$((FAILS + 1))
    fi
done

# 2. LIVE-FILE PARITY — only enforced if home-manager has actually deployed
if [ -f "$LIVE" ]; then
    src_mtime=$(stat -c%Y "$SRC")
    live_mtime=$(stat -c%Y "$LIVE")
    if [ "$live_mtime" -ge "$src_mtime" ]; then
        # Live file is fresh — assert it matches source
        live_fails=0
        for dir in "${REQUIRED_FOLDERS[@]}"; do
            grep -qF "$dir" "$LIVE" || { echo "✗ LIVE: folder NOT excluded in deployed file — $dir"; live_fails=$((live_fails + 1)); }
        done
        if [ "$live_fails" -eq 0 ]; then
            echo "✓ LIVE: $LIVE matches source"
        else
            FAILS=$((FAILS + live_fails))
        fi
    else
        echo "ℹ LIVE: $LIVE older than source — run ba_flakes_desktop/build.sh switch && balooctl6 purge && balooctl6 enable"
    fi
else
    echo "ℹ LIVE: $LIVE not present yet — run ba_flakes_desktop/build.sh switch first"
fi

if [ "$FAILS" -eq 0 ]; then
    echo "test-baloo-excludes: PASS"
    exit 0
else
    echo "test-baloo-excludes: FAIL ($FAILS check(s))"
    exit 1
fi
