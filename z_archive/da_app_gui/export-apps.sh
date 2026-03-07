#!/bin/bash
# Export all flatpak apps from distrobox to host desktop
#
# Usage: distrobox enter flatpak-box -- ./export-apps.sh
#        or run from host: ./export-apps.sh

set -e

APPS=(
    "com.brave.Browser"
    "org.libreoffice.LibreOffice"
    "md.obsidian.Obsidian"
    "com.visualstudio.code"
    "org.kde.dolphin"
    "org.kde.kate"
    "org.kde.okular"
    "org.kde.krita"
    "org.mozilla.Thunderbird"
    "com.slack.Slack"
    "com.spotify.Client"
    "com.protonvpn.www"
)

echo "=== Exporting Flatpak Apps to Host Desktop ==="
echo ""

# Check if we're inside distrobox
if [ -f /run/.containerenv ]; then
    # Inside container - use distrobox-export directly
    for app in "${APPS[@]}"; do
        echo "Exporting: $app"
        distrobox-export --app "$app" 2>/dev/null || echo "  (already exported or not found)"
    done
else
    # Outside container - use distrobox enter
    for app in "${APPS[@]}"; do
        echo "Exporting: $app"
        distrobox enter flatpak-box -- distrobox-export --app "$app" 2>/dev/null || echo "  (already exported or not found)"
    done
fi

echo ""
echo "=== Export Complete ==="
echo "Apps will appear in your application menu with 'flatpak-box-' prefix"
