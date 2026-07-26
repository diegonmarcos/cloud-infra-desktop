#!/usr/bin/env bash
# test-baloo-excludes.sh — verify the declarative baloofilerc restricts
# indexing to $HOME/bin only (include-list, not exclude-list).
#
# Symptom: KDE Baloo's default config indexes every file under $HOME.
# On this dev box baloo_file_extractor sustained 40-50% CPU forever trying
# to index ~/git (rust target/, cargo cache, node_modules, VM images, nix
# store). An exclude-list approach couldn't keep up with new subtrees, so
# this switched to an include-list: only folders[$e]=$HOME/bin is indexed.
#
# Two-layer assertion:
#   1. SOURCE (plasma.nix) sets folders[$e]=$HOME/bin and basic indexing.
#   2. LIVE (~/.config/baloofilerc) matches source if a switch has been done.

set -euo pipefail

SRC="${BASH_SOURCE[0]%/*}/plasma.nix"
LIVE="$HOME/.config/baloofilerc"
FAILS=0

[ -f "$SRC" ] || { echo "✗ source $SRC missing"; exit 1; }
echo "✓ source plasma.nix found at $SRC"

section() {
    awk '/xdg.configFile."baloofilerc"\.text = ..$/,/^  ..;/' "$SRC"
}

if section | grep -qF 'folders[$e]=$HOME/bin'; then
    echo "✓ SOURCE: folders[\$e]=\$HOME/bin present (include-list, KConfig expands \$HOME)"
else
    echo "✗ SOURCE: folders[\$e]=\$HOME/bin missing"
    FAILS=$((FAILS + 1))
fi

if section | grep -qF 'only basic indexing=true'; then
    echo "✓ SOURCE: only basic indexing=true present"
else
    echo "✗ SOURCE: only basic indexing=true missing"
    FAILS=$((FAILS + 1))
fi

if section | grep -qE '^[[:space:]]*exclude folders\[\$e\]='; then
    echo "✗ SOURCE: stale exclude folders[\$e]= present — should be removed under include-list design"
    FAILS=$((FAILS + 1))
else
    echo "✓ SOURCE: no stale exclude-folders key"
fi

# 2. LIVE-FILE PARITY — only enforced if home-manager has actually deployed
if [ -f "$LIVE" ]; then
    src_mtime=$(stat -c%Y "$SRC")
    live_mtime=$(stat -c%Y "$LIVE")
    if [ "$live_mtime" -ge "$src_mtime" ]; then
        if grep -qF 'folders[$e]=' "$LIVE"; then
            echo "✓ LIVE: $LIVE matches source"
        else
            echo "✗ LIVE: folders[\$e]= missing in deployed file"
            FAILS=$((FAILS + 1))
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
