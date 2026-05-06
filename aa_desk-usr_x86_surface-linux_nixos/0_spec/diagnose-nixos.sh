#!/bin/bash
# NixOS Impermanence Diagnostic & Fix Script
# Run from Ubuntu to diagnose and fix NixOS issues

set -e

POOL="/pool"
HOME_NIXOS="$POOL/@home-nixos/user"
PERSIST_HOME="$POOL/@root-nixos/persist/home/user"
JOURNAL_DIR="$POOL/@root-nixos/persist/var/log/journal"

echo "═══════════════════════════════════════════════════════════════════════════"
echo "                    NIXOS IMPERMANENCE DIAGNOSTIC"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# Check if pool is mounted
if ! mountpoint -q "$POOL" 2>/dev/null; then
    echo "[!] Pool not mounted. Mounting..."
    sudo mkdir -p "$POOL"
    sudo mount -o subvol=/ /dev/mapper/pool "$POOL" || {
        echo "[!] Failed to mount pool. Is LUKS unlocked?"
        echo "    Run: sudo cryptsetup open /dev/nvme0n1p4 pool"
        exit 1
    }
fi

echo "═══════════════════════════════════════════════════════════════════════════"
echo "1. JOURNAL ERRORS SUMMARY"
echo "═══════════════════════════════════════════════════════════════════════════"

if [ -d "$JOURNAL_DIR" ]; then
    echo ""
    echo "Top 30 errors by frequency:"
    echo "----------------------------"
    sudo journalctl -D "$JOURNAL_DIR" --no-pager -b 0 2>/dev/null | \
        grep -iE "error|fail|fatal|cannot|unable|denied|missing" | \
        grep -v "Module.*without build-id\|Stack trace\|#[0-9].*0x\|ELF object\|coredump" | \
        sed 's/Jan [0-9]* [0-9:.]*//g' | \
        sed 's/surface-nixos //g' | \
        sort | uniq -c | sort -rn | head -30

    echo ""
    echo "Failed services:"
    echo "----------------"
    sudo journalctl -D "$JOURNAL_DIR" --no-pager -b 0 2>/dev/null | \
        grep "Failed to start" | \
        sed 's/.*Failed to start /- /' | sort -u
else
    echo "[!] No journal found at $JOURNAL_DIR"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "2. HOME DIRECTORY STATUS"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

echo "Ownership check ($HOME_NIXOS):"
ls -la "$HOME_NIXOS" 2>/dev/null | head -15

echo ""
echo "Persist home ($PERSIST_HOME):"
ls -la "$PERSIST_HOME" 2>/dev/null | head -15

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "3. MISSING DIRECTORIES (from journal errors)"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# Extract missing directories from journal
MISSING_DIRS=$(sudo journalctl -D "$JOURNAL_DIR" --no-pager -b 0 2>/dev/null | \
    grep -oE '/home/user/\.[^"]*' | \
    sed 's/[^/]*$//' | \
    sort -u | \
    sed 's|/home/user|'"$HOME_NIXOS"'|g')

echo "Directories mentioned in errors:"
echo "$MISSING_DIRS" | head -30

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "4. APPLYING FIXES"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# Create all required directories
echo "[+] Creating required directories..."
mkdir -p "$HOME_NIXOS"/.config/{dconf,gtk-3.0,gtk-4.0,gtk-4.0/gtk,KDE,kwalletd,plasma-workspace,kglobalshortcuts,kwin,konsole,plasmashell,ktimezoned,kactivitymanagerd,baloofilerc,kconf_update,goa-1.0,evolution}
mkdir -p "$HOME_NIXOS"/.cache/{ksvg-elements,plasmashell,mesa_shader_cache,mesa_shader_cache_db,obexd,baloo,evolution,ksycoca5,icon-cache}
mkdir -p "$HOME_NIXOS"/.local/share/{kactivitymanagerd/resources,kwalletd,baloo,krunnerstaterc,plasma,konsole,recently-used.xbel,evolution,icons}
mkdir -p "$HOME_NIXOS"/.local/state/{wireplumber,plasmashell,kactivitymanagerd}
mkdir -p "$HOME_NIXOS"/{Documents,Downloads,Projects,.ssh,.gnupg}

# Create user-places.xbel if missing (KDE bookmarks)
if [ ! -f "$HOME_NIXOS/.local/share/user-places.xbel" ]; then
    rm -rf "$HOME_NIXOS/.local/share/user-places.xbel" 2>/dev/null || true
    cat > "$HOME_NIXOS/.local/share/user-places.xbel" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE xbel>
<xbel xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks" xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info" xmlns:kdeconnect="http://www.kde.org/kdeconnect">
</xbel>
EOF
fi

# Create picom config if missing
if [ ! -f "$HOME_NIXOS/.config/picom.conf" ]; then
    cat > "$HOME_NIXOS/.config/picom.conf" << 'EOF'
backend = "glx";
shadow = false;
fading = true;
fade-delta = 5;
vsync = true;
EOF
fi

echo "[+] Fixing ownership (UID 1000)..."
chown -R 1000:1000 "$HOME_NIXOS"
chown -R 1000:1000 "$PERSIST_HOME" 2>/dev/null || true

echo "[+] Setting permissions..."
chmod 700 "$HOME_NIXOS"/.ssh 2>/dev/null || true
chmod 700 "$HOME_NIXOS"/.gnupg 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "5. VERIFICATION"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

echo "Directory count: $(find "$HOME_NIXOS" -type d 2>/dev/null | wc -l)"
echo "Ownership check:"
ls -la "$HOME_NIXOS" 2>/dev/null | head -5

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "6. NIX STORE STATUS"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

echo "Nix store size: $(du -sh "$POOL/@root-nixos/nix/store" 2>/dev/null | cut -f1)"
echo "Packages count: $(ls "$POOL/@root-nixos/nix/store" 2>/dev/null | wc -l)"
echo "Current system: $(readlink "$POOL/@root-nixos/nix/var/nix/profiles/system" 2>/dev/null)"

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "DONE! Boot into NixOS to test."
echo "═══════════════════════════════════════════════════════════════════════════"
