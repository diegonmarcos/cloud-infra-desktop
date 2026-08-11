#!/usr/bin/env bash
# Check plasma-systray-config.sh against a fixture appletsrc:
#   - both tray containments get configured (the old awk stopped at the first)
#   - hiddenItems is the complement, so an id nobody predicted (my-ai-usage,
#     Xwayland Video Bridge) lands in hidden and not on the panel
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export SYSTRAY_APPLETS_FILE="$TMP/appletsrc"
export SYSTRAY_ITEMS_JSON="$SELF_DIR/systray-items.json"
export HOME="$TMP"

cat > "$SYSTRAY_APPLETS_FILE" <<'EOF'
[Containments][3806]
plugin=org.kde.panel

[Containments][3806][Applets][3807]
plugin=org.kde.plasma.systemtray

[Containments][3816]
plugin=org.kde.plasma.private.systemtray

[Containments][3816][General]
knownItems=org.kde.plasma.battery,my-ai-usage,cloud-systray
shownItems=cloud-systray,Xwayland Video Bridge_pipewireToXProxy

[Containments][3828]
plugin=org.kde.plasma.private.systemtray

[Containments][3828][General]
knownItems=org.kde.plasma.diskquota,org.kde.plasma.keyboardlayout
EOF

bash "$SELF_DIR/plasma-systray-config.sh" > "$TMP/log"

get() { kreadconfig6 --file "$SYSTRAY_APPLETS_FILE" --group Containments --group "$1" --group General --key "$2"; }

fail() { echo "FAIL: $1" >&2; exit 1; }
has() { case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# tray 1: ours shown, everything else hidden
has cloud-systray "$(get 3816 shownItems)" || fail "tray1 missing cloud-systray in shownItems"
has org.kde.plasma.battery "$(get 3816 hiddenItems)" || fail "tray1 did not hide battery"
has "my-ai-usage" "$(get 3816 hiddenItems)" || fail "tray1 did not hide the undeclared my-ai-usage"
has "Xwayland Video Bridge_pipewireToXProxy" "$(get 3816 hiddenItems)" ||
  fail "tray1 did not hide the undeclared Xwayland bridge"
has org.kde.plasma.battery "$(get 3816 shownItems)" && fail "tray1 still shows battery"

# tray 2: the second containment must be configured too, KDE items shown
has org.kde.plasma.battery "$(get 3828 shownItems)" || fail "tray2 missing battery in shownItems"
has cloud-systray "$(get 3828 hiddenItems)" || fail "tray2 did not hide cloud-systray"
has org.kde.plasma.keyboardlayout "$(get 3828 hiddenItems)" || fail "tray2 did not hide keyboardlayout"
has org.kde.plasma.diskquota "$(get 3828 hiddenItems)" || fail "tray2 did not hide the undeclared diskquota"

echo "PASS: both trays configured, undeclared items hidden"
