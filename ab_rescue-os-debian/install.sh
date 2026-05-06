#!/bin/bash
# Debian Rescue OS - Post-Boot Configurator
# Run after first boot of the Debian rescue OS (from ~/git/unix/...).
# Verifies installation, fills in any missed packages, and provides
# convenience launchers for browser / claude / mount helpers.
#
# Usage: ./install.sh [scan|install|browser|session|kiosk|claude|mount-pool|mount-all|help]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/install.json"
LOGFILE="$SCRIPT_DIR/install_log.md"
CHECKFILE="$SCRIPT_DIR/install_check.md"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

usage() {
    cat <<EOF

Debian Rescue OS — Post-Boot Configurator

Usage: ./install.sh [command]

Commands:
  scan         Check packages, services, mounts; output install_check.md
  install      Install missing packages from install.json (idempotent)
  browser      One-shot Firefox via xinit (no WM) — for Claude OAuth
  session      Full i3 tiling session via startx
  kiosk        Wayland kiosk: cage -- firefox-esr
  claude       Launch Claude Code (assumes auth done; opens browser if needed)
  mount-pool   Unlock LUKS pool and mount /mnt/pool
  mount-all    Attempt to mount every noauto entry in fstab (skips encrypted)
  help         This message

Recommended first-boot order:
  1. ./install.sh scan
  2. ./install.sh install      # picks up anything chroot install missed
  3. ./install.sh browser      # Firefox for Claude OAuth login
  4. ./install.sh claude       # use Claude Code

Config: $CONFIG

EOF
    exit 0
}

log_ok()   { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
log_miss() { printf "${RED}[MISS]${NC} %s\n" "$1"; }
log_info() { printf "${YELLOW}[INFO]${NC} %s\n" "$1"; }
log_head() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
log_err()  { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }

check_jq() {
    command -v jq >/dev/null 2>&1 || { log_info "Installing jq..."; sudo apt-get install -y jq; }
}

check_config() {
    [ -f "$CONFIG" ] || log_err "$CONFIG not found"
}

SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

# ────────────────────────────────────────────────────────────────────────────
# scan
# ────────────────────────────────────────────────────────────────────────────

cmd_scan() {
    check_jq; check_config
    log_head "Scanning Packages, Services, Mounts"

    cat > "$CHECKFILE" <<EOF
# Debian Rescue OS — Install Check

> Generated: $(date '+%Y-%m-%d %H:%M:%S')
> Config:    $CONFIG

---

## APT Packages

EOF

    INSTALLED=0; MISSING=0

    for category in $(jq -r '.apt | keys[]' "$CONFIG"); do
        echo "### $category" >> "$CHECKFILE"
        for pkg in $(jq -r ".apt.$category[]" "$CONFIG"); do
            if dpkg -s "$pkg" >/dev/null 2>&1; then
                log_ok "$pkg"
                echo "- [x] $pkg" >> "$CHECKFILE"
                INSTALLED=$((INSTALLED+1))
            else
                log_miss "$pkg"
                echo "- [ ] $pkg" >> "$CHECKFILE"
                MISSING=$((MISSING+1))
            fi
        done
        echo "" >> "$CHECKFILE"
    done

    echo "## NPM Globals" >> "$CHECKFILE"; echo "" >> "$CHECKFILE"
    for pkg in $(jq -r '.npm.global[]' "$CONFIG"); do
        if npm list -g --depth=0 "$pkg" 2>/dev/null | grep -q "$pkg@"; then
            log_ok "$pkg (npm)"
            echo "- [x] $pkg" >> "$CHECKFILE"
        else
            log_miss "$pkg (npm)"
            echo "- [ ] $pkg" >> "$CHECKFILE"
            MISSING=$((MISSING+1))
        fi
    done
    echo "" >> "$CHECKFILE"

    echo "## Services" >> "$CHECKFILE"; echo "" >> "$CHECKFILE"
    for svc in $(jq -r '.services.enable[]' "$CONFIG"); do
        if systemctl is-enabled "$svc" >/dev/null 2>&1; then
            log_ok "service: $svc"
            echo "- [x] $svc" >> "$CHECKFILE"
        else
            log_miss "service: $svc"
            echo "- [ ] $svc" >> "$CHECKFILE"
        fi
    done
    echo "" >> "$CHECKFILE"

    echo "---" >> "$CHECKFILE"
    echo "## Summary" >> "$CHECKFILE"
    echo "- Installed: $INSTALLED" >> "$CHECKFILE"
    echo "- Missing:   $MISSING" >> "$CHECKFILE"

    log_head "Scan Complete"
    log_info "Installed: $INSTALLED"
    log_info "Missing:   $MISSING"
    log_info "Details:   $CHECKFILE"
}

# ────────────────────────────────────────────────────────────────────────────
# install
# ────────────────────────────────────────────────────────────────────────────

cmd_install() {
    check_jq; check_config
    log_head "Installing missing packages"

    ALL_PKGS=""
    for category in $(jq -r '.apt | keys[]' "$CONFIG"); do
        ALL_PKGS="$ALL_PKGS $(jq -r ".apt.$category[]" "$CONFIG" | tr '\n' ' ')"
    done

    log_info "Running apt-get install (idempotent)..."
    $SUDO apt-get update -qq
    $SUDO apt-get install -y --no-install-recommends $ALL_PKGS

    # Node — if missing, add NodeSource
    if ! command -v node >/dev/null 2>&1; then
        log_info "Installing Node.js LTS via NodeSource..."
        $SUDO mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
            $SUDO gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | \
            $SUDO tee /etc/apt/sources.list.d/nodesource.list >/dev/null
        $SUDO apt-get update -qq
        $SUDO apt-get install -y --no-install-recommends nodejs
    fi

    # NPM globals
    for pkg in $(jq -r '.npm.global[]' "$CONFIG"); do
        if ! npm list -g --depth=0 "$pkg" 2>/dev/null | grep -q "$pkg@"; then
            log_info "Installing npm global: $pkg"
            $SUDO npm install -g "$pkg" || log_info "npm: $pkg failed"
        fi
    done

    # Enable services
    for svc in $(jq -r '.services.enable[]' "$CONFIG"); do
        $SUDO systemctl enable --now "$svc" 2>/dev/null || true
        log_ok "service: $svc"
    done

    echo "- $(date '+%Y-%m-%d %H:%M'): install run completed" >> "$LOGFILE"
    log_head "Install Complete"
}

# ────────────────────────────────────────────────────────────────────────────
# browser / session / kiosk
# ────────────────────────────────────────────────────────────────────────────

cmd_browser() {
    log_head "Launching Firefox (one-shot, no WM)"
    command -v startx >/dev/null 2>&1 || log_err "startx not found — run: ./install.sh install"
    command -v firefox-esr >/dev/null 2>&1 || log_err "firefox-esr not found"
    exec startx /usr/bin/firefox-esr -- :0 vt$(tty | sed 's|/dev/tty||')
}

cmd_session() {
    log_head "Launching i3 session via startx"
    command -v startx >/dev/null 2>&1 || log_err "startx not found"
    command -v i3 >/dev/null 2>&1 || log_err "i3 not found"
    if [ ! -f "$HOME/.xinitrc" ]; then
        echo "exec i3" > "$HOME/.xinitrc"
        log_info "Created $HOME/.xinitrc"
    fi
    exec startx
}

cmd_kiosk() {
    log_head "Launching Wayland kiosk (cage + firefox-esr)"
    command -v cage >/dev/null 2>&1 || log_err "cage not found"
    exec cage -- firefox-esr
}

# ────────────────────────────────────────────────────────────────────────────
# claude
# ────────────────────────────────────────────────────────────────────────────

cmd_claude() {
    log_head "Launching Claude Code"
    if ! command -v claude >/dev/null 2>&1; then
        log_err "claude not installed. Run: $SUDO npm install -g @anthropic-ai/claude-code"
    fi
    exec claude
}

# ────────────────────────────────────────────────────────────────────────────
# mount helpers
# ────────────────────────────────────────────────────────────────────────────

cmd_mount_pool() {
    log_head "Unlocking + mounting LUKS pool"
    if [ ! -e /dev/mapper/pool ]; then
        $SUDO cryptsetup open /dev/nvme0n1p4 pool
    else
        log_info "pool already unlocked"
    fi
    $SUDO mkdir -p /mnt/pool
    if ! mountpoint -q /mnt/pool; then
        $SUDO mount /mnt/pool || $SUDO mount -t btrfs /dev/mapper/pool /mnt/pool
        log_ok "Mounted /mnt/pool"
    else
        log_info "/mnt/pool already mounted"
    fi
    log_info "Subvolumes available — see: ls /mnt/pool"
}

cmd_mount_all() {
    log_head "Mounting all noauto fstab entries (encrypted skipped)"
    while read -r src tgt fs opts dump pass; do
        case "$src" in ''|\#*) continue ;; esac
        case "$opts" in *noauto*) ;; *) continue ;; esac
        case "$src" in /dev/mapper/*) log_info "skip $tgt (encrypted — use mount-pool)"; continue ;; esac
        if mountpoint -q "$tgt"; then
            log_info "$tgt already mounted"
        else
            $SUDO mount "$tgt" 2>/dev/null && log_ok "Mounted $tgt" || log_miss "Failed $tgt"
        fi
    done < /etc/fstab
}

# ────────────────────────────────────────────────────────────────────────────
# main
# ────────────────────────────────────────────────────────────────────────────

case "${1:-help}" in
    scan)        cmd_scan ;;
    install)     cmd_install ;;
    browser)     cmd_browser ;;
    session)     cmd_session ;;
    kiosk)       cmd_kiosk ;;
    claude)      cmd_claude ;;
    mount-pool)  cmd_mount_pool ;;
    mount-all)   cmd_mount_all ;;
    help|*)      usage ;;
esac
