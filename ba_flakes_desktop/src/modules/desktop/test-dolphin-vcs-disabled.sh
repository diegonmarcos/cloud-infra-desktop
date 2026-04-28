#!/usr/bin/env bash
# test-dolphin-vcs-disabled.sh — verify Dolphin's VCS git plugin is
# declaratively disabled.
#
# Symptom: load avg sustained at 6+ with apparently nothing happening.
# Evidence pinned the cause: 6.5 cores of `git --no-optional-locks status
# --porcelain --ignored` constantly running, every PPID = .dolphin-wrappe.
# The KDE Dolphin "Version Control: Git" plugin walks every directory
# shown including ignored files (= rust target/, node_modules, dist/),
# auto-refreshing on inotify events.
#
# Fix lives in plasma.nix — `xdg.configFile."dolphinrc"` writes:
#   [VersionControl]
#   enabledPlugins=
#
# Two-layer assertion:
#   1. SOURCE (plasma.nix) declares the [VersionControl] block with
#      enabledPlugins= empty.
#   2. LIVE (~/.config/dolphinrc) matches source after switch — and the
#      tester warns if Dolphin needs restart to pick up the change.

set -euo pipefail

SRC="${BASH_SOURCE[0]%/*}/plasma.nix"
LIVE="$HOME/.config/dolphinrc"
FAILS=0

[ -f "$SRC" ] || { echo "✗ source $SRC missing"; exit 1; }
echo "✓ source plasma.nix found"

# 1. SOURCE-LEVEL — the plasma-manager configFile entry sets
# "dolphinrc"."VersionControl"."enabledPlugins" = "";
# (We no longer use xdg.configFile here because plasma-manager owns
# dolphinrc — read-only-fs collision otherwise.)
if grep -qE '"dolphinrc"\."VersionControl"' "$SRC"; then
    echo "✓ SOURCE: programs.plasma.configFile has dolphinrc.VersionControl"
else
    echo "✗ SOURCE: missing dolphinrc.VersionControl entry"
    FAILS=$((FAILS + 1))
fi

# Look at the next ~3 lines after VersionControl declaration for empty enabledPlugins
if awk '/"dolphinrc"\."VersionControl"/,/^[[:space:]]*\}/' "$SRC" | grep -qE 'enabledPlugins[[:space:]]*=[[:space:]]*"";'; then
    echo "✓ SOURCE: enabledPlugins = \"\" (VCS plugins disabled)"
else
    echo "✗ SOURCE: enabledPlugins not empty — git plugin still loadable"
    FAILS=$((FAILS + 1))
fi

# 2. LIVE-FILE PARITY
if [ -L "$LIVE" ] || [ -f "$LIVE" ]; then
    src_mtime=$(stat -c%Y "$SRC")
    live_mtime=$(stat -Lc%Y "$LIVE")
    if [ "$live_mtime" -ge "$src_mtime" ]; then
        # Live is fresh — assert it matches
        if grep -qE '^enabledPlugins=[[:space:]]*$' "$LIVE" \
           && grep -q '^\[VersionControl\]' "$LIVE"; then
            echo "✓ LIVE: dolphinrc declares enabledPlugins= empty"
        else
            echo "✗ LIVE: dolphinrc does not have enabledPlugins= empty under [VersionControl]"
            grep -A1 '^\[VersionControl\]' "$LIVE" 2>/dev/null | sed 's/^/    /' || echo "    (no [VersionControl] section in deployed file)"
            FAILS=$((FAILS + 1))
        fi
    else
        echo "ℹ LIVE: $LIVE older than source — run ba_flakes_desktop/build.sh switch then kquitapp6 dolphin"
    fi
else
    echo "ℹ LIVE: $LIVE not present yet — run ba_flakes_desktop/build.sh switch first"
fi

# 3. RUNTIME — flag if a Dolphin instance is running with the OLD config
# (Dolphin holds dolphinrc in memory; the new file alone doesn't take
# effect until kquitapp6 dolphin / fresh Dolphin launch).
if pgrep -af "dolphin\|dolphin-wrappe" >/dev/null 2>&1; then
    # Running. Check if any git children are spawning right now.
    git_kids=$(pgrep -P "$(pgrep -d, -f 'dolphin-wrappe\|^dolphin' 2>/dev/null)" 2>/dev/null | xargs -r ps -o comm= -p 2>/dev/null | grep -c '^git$' || true)
    if [ "${git_kids:-0}" -gt 0 ]; then
        echo "ℹ RUNTIME: Dolphin is alive AND spawning git children — restart it: kquitapp6 dolphin"
    else
        echo "✓ RUNTIME: Dolphin is alive but not currently spawning git (config picked up OR window idle)"
    fi
else
    echo "ℹ RUNTIME: Dolphin not running — fix takes effect on next launch"
fi

if [ "$FAILS" -eq 0 ]; then
    echo "test-dolphin-vcs-disabled: PASS"
    exit 0
else
    echo "test-dolphin-vcs-disabled: FAIL ($FAILS check(s))"
    exit 1
fi
