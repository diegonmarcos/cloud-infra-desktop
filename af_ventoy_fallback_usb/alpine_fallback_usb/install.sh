#!/bin/sh
# Alpine Recovery - Setup Script
# Usage: ./install.sh [scan|install|desktop|help]
# POSIX compliant

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/install.json"
LOGFILE="$SCRIPT_DIR/install_log.md"
CHECKFILE="$SCRIPT_DIR/install_check.md"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

###################
# HELPER FUNCTIONS
###################

usage() {
    echo ""
    echo "Alpine Recovery - Setup Script"
    echo ""
    echo "Usage: ./install.sh [command]"
    echo ""
    echo "Commands:"
    echo "  scan      Check packages, output install_check.md"
    echo "  install   Install missing packages and configure"
    echo "  desktop   Start Openbox desktop (startx)"
    echo "  help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./install.sh scan      # Check what's missing"
    echo "  ./install.sh install   # Install everything"
    echo "  ./install.sh desktop   # Start GUI"
    echo ""
    echo "Config: $CONFIG"
    echo ""
    exit 0
}

log_ok()   { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
log_miss() { printf "${RED}[MISS]${NC} %s\n" "$1"; }
log_info() { printf "${YELLOW}[INFO]${NC} %s\n" "$1"; }
log_head() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }

check_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Installing jq..."
        sudo apk add --no-cache jq
    fi
}

check_config() {
    if [ ! -f "$CONFIG" ]; then
        echo "ERROR: $CONFIG not found"
        exit 1
    fi
}

# Sudo check
SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

###################
# SCAN COMMAND
###################

cmd_scan() {
    check_jq
    check_config
    
    log_head "Scanning Packages"
    
    # Start check file
    cat > "$CHECKFILE" << EOF
# Alpine Recovery - Package Check

> Generated: $(date '+%Y-%m-%d %H:%M:%S')
> Config: $CONFIG

---

EOF

    # APK packages
    echo "## APK Packages" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"
    
    ALL_APK=$(jq -r '.apk | to_entries[] | "\(.key):\(.value[])"' "$CONFIG")
    
    INSTALLED=0
    MISSING=0
    MISSING_LIST=""
    
    CURRENT_CAT=""
    for entry in $ALL_APK; do
        CAT=$(echo "$entry" | cut -d: -f1)
        PKG=$(echo "$entry" | cut -d: -f2)
        
        if [ "$CAT" != "$CURRENT_CAT" ]; then
            echo "" >> "$CHECKFILE"
            echo "### $CAT" >> "$CHECKFILE"
            echo "" >> "$CHECKFILE"
            CURRENT_CAT="$CAT"
        fi
        
        if apk info -e "$PKG" >/dev/null 2>&1; then
            log_ok "$PKG"
            echo "- [x] \`$PKG\`" >> "$CHECKFILE"
            INSTALLED=$((INSTALLED + 1))
        else
            log_miss "$PKG"
            echo "- [ ] \`$PKG\` **MISSING**" >> "$CHECKFILE"
            MISSING=$((MISSING + 1))
            MISSING_LIST="$MISSING_LIST $PKG"
        fi
    done
    
    # NPM packages
    echo "" >> "$CHECKFILE"
    echo "## NPM Packages" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"
    
    log_head "NPM Packages"
    
    NPM_GLOBAL=$(jq -r '.npm.global[]' "$CONFIG" 2>/dev/null)
    NPM_OPT=$(jq -r '.npm.optional[]' "$CONFIG" 2>/dev/null)
    
    for pkg in $NPM_GLOBAL; do
        if npm list -g "$pkg" >/dev/null 2>&1; then
            log_ok "$pkg"
            echo "- [x] \`$pkg\`" >> "$CHECKFILE"
        else
            log_miss "$pkg"
            echo "- [ ] \`$pkg\` **MISSING**" >> "$CHECKFILE"
            MISSING=$((MISSING + 1))
        fi
    done
    
    for pkg in $NPM_OPT; do
        if npm list -g "$pkg" >/dev/null 2>&1; then
            log_ok "$pkg (optional)"
            echo "- [x] \`$pkg\` (optional)" >> "$CHECKFILE"
        else
            log_miss "$pkg (optional)"
            echo "- [ ] \`$pkg\` (optional)" >> "$CHECKFILE"
        fi
    done
    
    # PIP packages
    echo "" >> "$CHECKFILE"
    echo "## PIP Packages" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"
    
    log_head "PIP Packages"
    
    PIP_GLOBAL=$(jq -r '.pip.global[]' "$CONFIG" 2>/dev/null)
    
    for pkg in $PIP_GLOBAL; do
        if pip3 show "$pkg" >/dev/null 2>&1; then
            log_ok "$pkg"
            echo "- [x] \`$pkg\`" >> "$CHECKFILE"
        else
            log_miss "$pkg"
            echo "- [ ] \`$pkg\` **MISSING**" >> "$CHECKFILE"
            MISSING=$((MISSING + 1))
        fi
    done
    
    # Services
    echo "" >> "$CHECKFILE"
    echo "## Services" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"
    
    log_head "Services"
    
    SERVICES=$(jq -r '.services.default[]' "$CONFIG")
    
    for svc in $SERVICES; do
        if $SUDO rc-update show default 2>/dev/null | grep -q "$svc"; then
            log_ok "$svc"
            echo "- [x] \`$svc\` enabled" >> "$CHECKFILE"
        else
            log_miss "$svc"
            echo "- [ ] \`$svc\` **NOT ENABLED**" >> "$CHECKFILE"
        fi
    done
    
    # Summary
    echo "" >> "$CHECKFILE"
    echo "---" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"
    echo "## Summary" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"
    echo "| Status | Count |" >> "$CHECKFILE"
    echo "|--------|-------|" >> "$CHECKFILE"
    echo "| Installed | $INSTALLED |" >> "$CHECKFILE"
    echo "| Missing | $MISSING |" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"
    
    if [ -n "$MISSING_LIST" ]; then
        echo "### Missing APK Packages" >> "$CHECKFILE"
        echo "" >> "$CHECKFILE"
        echo "\`\`\`" >> "$CHECKFILE"
        echo "sudo apk add$MISSING_LIST" >> "$CHECKFILE"
        echo "\`\`\`" >> "$CHECKFILE"
    fi
    
    echo ""
    log_info "Report saved to: $CHECKFILE"
    echo ""
    echo "Summary: $INSTALLED installed, $MISSING missing"
    echo ""
}

###################
# INSTALL COMMAND
###################

cmd_install() {
    check_jq
    check_config
    
    NAME=$(jq -r '.meta.name' "$CONFIG")
    VERSION=$(jq -r '.meta.version' "$CONFIG")
    
    # Start log entry
    cat >> "$LOGFILE" << EOF

---

## Session: $(date '+%Y-%m-%d %H:%M:%S')

**Host:** $(hostname)
**User:** $(whoami)
**Command:** install

EOF

    log_head "$NAME v$VERSION - Install"
    
    # APK packages
    log_head "APK Packages"
    
    ALL_APK=$(jq -r '.apk | to_entries[] | .value[]' "$CONFIG" | tr '\n' ' ')
    
    MISSING=""
    for pkg in $ALL_APK; do
        if apk info -e "$pkg" >/dev/null 2>&1; then
            log_ok "$pkg"
            echo "- [x] $pkg" >> "$LOGFILE"
        else
            log_miss "$pkg"
            echo "- [ ] $pkg (missing)" >> "$LOGFILE"
            MISSING="$MISSING $pkg"
        fi
    done
    
    if [ -n "$MISSING" ]; then
        log_info "Installing missing packages..."
        echo "" >> "$LOGFILE"
        echo "Installing:$MISSING" >> "$LOGFILE"
        $SUDO apk add --no-cache $MISSING >> "$LOGFILE" 2>&1 || true
        log_ok "APK installation complete"
    fi
    
    # NPM packages
    log_head "NPM Packages"
    
    NPM_GLOBAL=$(jq -r '.npm.global[]' "$CONFIG" 2>/dev/null)
    
    for pkg in $NPM_GLOBAL; do
        if npm list -g "$pkg" >/dev/null 2>&1; then
            log_ok "$pkg"
        else
            log_info "Installing $pkg..."
            npm install -g "$pkg" >> "$LOGFILE" 2>&1 || log_info "Failed: $pkg"
        fi
    done
    
    NPM_OPT=$(jq -r '.npm.optional[]' "$CONFIG" 2>/dev/null)
    
    for pkg in $NPM_OPT; do
        if npm list -g "$pkg" >/dev/null 2>&1; then
            log_ok "$pkg (optional)"
        else
            log_info "Installing $pkg (optional)..."
            npm install -g "$pkg" >> "$LOGFILE" 2>&1 || log_info "Skipped: $pkg"
        fi
    done
    
    # PIP packages
    log_head "PIP Packages"
    
    PIP_GLOBAL=$(jq -r '.pip.global[]' "$CONFIG" 2>/dev/null)
    
    for pkg in $PIP_GLOBAL; do
        if pip3 show "$pkg" >/dev/null 2>&1; then
            log_ok "$pkg"
        else
            log_info "Installing $pkg..."
            pip3 install "$pkg" >> "$LOGFILE" 2>&1 || log_info "Skipped: $pkg"
        fi
    done
    
    # Services
    log_head "Services"
    
    SERVICES=$(jq -r '.services.default[]' "$CONFIG")
    
    for svc in $SERVICES; do
        if $SUDO rc-update show default 2>/dev/null | grep -q "$svc"; then
            log_ok "$svc"
        else
            $SUDO rc-update add "$svc" default >> "$LOGFILE" 2>&1 && log_ok "$svc enabled"
        fi
    done
    
    # Openbox config
    log_head "Openbox Configuration"
    
    mkdir -p "$HOME/.config/openbox"
    
    cat > "$HOME/.config/openbox/menu.xml" << 'MENUHEAD'
<?xml version="1.0" encoding="utf-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Apps">
MENUHEAD

    jq -r '.openbox.menu[] | 
        if .type == "separator" then 
            "    <separator/>"
        elif .submenu then
            "    <menu id=\"\(.label | gsub(\" \"; \"-\") | ascii_downcase)-menu\" label=\"\(.label)\">\n" +
            (.submenu | map("      <item label=\"\(.label)\"><action name=\"Execute\"><execute>\(.cmd)</execute></action></item>") | join("\n")) +
            "\n    </menu>"
        elif .action then
            "    <item label=\"\(.label)\"><action name=\"\(.action)\"/></item>"
        else
            "    <item label=\"\(.label)\"><action name=\"Execute\"><execute>\(.cmd)</execute></action></item>"
        end' "$CONFIG" >> "$HOME/.config/openbox/menu.xml"

    cat >> "$HOME/.config/openbox/menu.xml" << 'MENUFOOT'
  </menu>
</openbox_menu>
MENUFOOT

    cat > "$HOME/.config/openbox/autostart" << 'EOF'
xterm &
EOF

    cat > "$HOME/.xinitrc" << 'EOF'
exec openbox-session
EOF

    log_ok "Openbox configured"
    
    # Shell config
    log_head "Shell"
    
    USER_SHELL=$(jq -r '.users.diego.shell' "$CONFIG")
    CURRENT_SHELL=$(getent passwd "$USER" | cut -d: -f7)
    
    if [ "$CURRENT_SHELL" != "$USER_SHELL" ]; then
        printf "Set $USER_SHELL as default? [y/N] "
        read -r ans
        if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
            $SUDO chsh -s "$USER_SHELL" "$USER"
            log_ok "Shell: $USER_SHELL"
        fi
    else
        log_ok "Shell: $USER_SHELL"
    fi
    
    # Done
    echo "" >> "$LOGFILE"
    echo "**Completed:** $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOGFILE"
    
    log_head "Install Complete"
    echo ""
    echo "Log: $LOGFILE"
    echo ""
    echo "Run './install.sh desktop' to start GUI"
    echo ""
}

###################
# DESKTOP COMMAND
###################

cmd_desktop() {
    log_info "Starting Openbox desktop..."
    
    if [ ! -f "$HOME/.xinitrc" ]; then
        log_info "Creating .xinitrc..."
        echo "exec openbox-session" > "$HOME/.xinitrc"
    fi
    
    exec startx
}

###################
# MAIN
###################

case "${1:-}" in
    scan)
        cmd_scan
        ;;
    install)
        cmd_install
        ;;
    desktop)
        cmd_desktop
        ;;
    help|-h|--help)
        usage
        ;;
    "")
        usage
        ;;
    *)
        echo "Unknown command: $1"
        usage
        ;;
esac
