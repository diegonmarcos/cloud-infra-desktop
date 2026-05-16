#!/bin/bash
# Kali Linux Surface - Setup Script
# Usage: ./install.sh [scan|install|surface|kali|desktop|help]

set -Eeuo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# VERBOSE ERROR HANDLING — POST-INCIDENT 2026-05-16
# Reason: install.sh previously had `set -e` only. Errors aborted but produced
# no context (no command, no line, no exit code) — so silent failures during
# install were possible. After the 2026-05-15 incident, where a `mount: command
# not found` warning during nixos-install activation passed unnoticed and led
# to a broken first-boot login, we standardise on LOUD failure across every
# install script. This trap fires on ANY non-zero exit and prints a 4-line
# banner with the failing command, line, exit code, and caller chain.
# ─────────────────────────────────────────────────────────────────────────────
_err_banner() {
    local exit_code=$?
    local line=${1:-?}
    local cmd=${2:-?}
    local chain
    chain="$(for ((i=0; i<${#FUNCNAME[@]}; i++)); do printf '%s:' "${FUNCNAME[$i]:-MAIN}"; done | sed 's/:$//')"
    printf '\n\033[0;31m╔══════════════════════════════════════════════════════════════════╗\n'
    printf       '║  install.sh — FAILED                                             ║\n'
    printf       '╚══════════════════════════════════════════════════════════════════╝\033[0m\n'
    printf '  exit code : %d\n' "$exit_code"
    printf '  line      : %s\n' "$line"
    printf '  command   : %s\n' "$cmd"
    printf '  call chain: %s\n' "$chain"
    printf '  log       : %s\n' "$LOGFILE"
    echo "- $(date '+%Y-%m-%d %H:%M:%S'): FAILED at line $line (exit=$exit_code): $cmd" >> "$LOGFILE" 2>/dev/null || true
    exit "$exit_code"
}
trap '_err_banner "$LINENO" "$BASH_COMMAND"' ERR

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
    echo "Kali Linux Surface - Setup Script"
    echo ""
    echo "Usage: ./install.sh [command]"
    echo ""
    echo "Commands:"
    echo "  surface    Verify/install linux-surface drivers"
    echo "  scan       Check packages, output install_check.md"
    echo "  install    Install base packages and configure"
    echo "  kali       Install Kali security tools"
    echo "  webserver  Deploy http-dev (Markdown + Eruda file server)"
    echo "  fstab      Sync /etc/fstab + /etc/crypttab + swapfile from install.json"
    echo "  desktop    Start Openbox desktop (startx)"
    echo "  sway       Start Sway (Wayland)"
    echo "  help       Show this help message"
    echo ""
    echo "Recommended order:"
    echo "  1. ./install.sh surface    # Verify Surface drivers"
    echo "  2. ./install.sh scan       # Check what's missing"
    echo "  3. ./install.sh install    # Install base packages"
    echo "  4. ./install.sh kali       # Install security tools"
    echo "  5. ./install.sh webserver  # Deploy http-dev file server"
    echo "  6. ./install.sh desktop    # Start GUI"
    echo ""
    echo "Config: $CONFIG"
    echo ""
    exit 0
}

log_ok()   { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
log_miss() { printf "${RED}[MISS]${NC} %s\n" "$1"; }
log_info() { printf "${YELLOW}[INFO]${NC} %s\n" "$1"; }
log_head() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
log_err()  { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }

check_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Installing jq..."
        sudo apt-get install -y jq
    fi
}

check_config() {
    if [ ! -f "$CONFIG" ]; then
        log_err "$CONFIG not found"
    fi
}

# Sudo check
SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

###################
# SURFACE COMMAND
###################

cmd_surface() {
    log_head "Checking linux-surface Drivers"

    # Check if kernel is installed
    if dpkg -l | grep -q "linux-image-surface"; then
        log_ok "linux-image-surface installed"
    else
        log_miss "linux-image-surface not installed"
        log_info "Installing linux-surface..."

        # Add repo if not present
        if [ ! -f /etc/apt/sources.list.d/linux-surface.list ]; then
            wget -qO - https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc \
                | gpg --dearmor | $SUDO tee /etc/apt/trusted.gpg.d/linux-surface.gpg > /dev/null
            echo "deb [arch=amd64] https://pkg.surfacelinux.com/debian release main" \
                | $SUDO tee /etc/apt/sources.list.d/linux-surface.list
            $SUDO apt-get update
        fi

        $SUDO apt-get install -y linux-image-surface linux-headers-surface iptsd
        $SUDO systemctl enable iptsd

        log_ok "linux-surface installed!"
        echo ""
        echo "========================================"
        echo "  REBOOT NOW for keyboard to work!"
        echo "  Run: sudo reboot"
        echo "========================================"
        return
    fi

    # Check iptsd
    if dpkg -l | grep -q "iptsd"; then
        log_ok "iptsd installed"
    else
        log_miss "iptsd not installed"
        $SUDO apt-get install -y iptsd
        $SUDO systemctl enable iptsd
    fi

    # Check modules
    if lsmod | grep -q "surface_aggregator"; then
        log_ok "surface_aggregator module loaded"
    else
        log_info "surface_aggregator not loaded (may need reboot)"
    fi

    if lsmod | grep -q "surface_hid"; then
        log_ok "surface_hid (keyboard) module loaded"
    else
        log_info "surface_hid not loaded (may need reboot)"
    fi

    # Check iptsd service
    if systemctl is-active --quiet iptsd 2>/dev/null; then
        log_ok "iptsd service running"
    else
        log_info "iptsd service not running"
    fi

    # Log
    echo "- $(date '+%Y-%m-%d %H:%M'): Surface check completed" >> "$LOGFILE"
}

###################
# SCAN COMMAND
###################

cmd_scan() {
    check_jq
    check_config

    log_head "Scanning Packages"

    # Start check file
    cat > "$CHECKFILE" << EOF
# Kali Linux Surface - Package Check

> Generated: $(date '+%Y-%m-%d %H:%M:%S')
> Config: $CONFIG

---

EOF

    # Surface drivers first
    echo "## Surface Drivers" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"

    for pkg in linux-image-surface linux-headers-surface iptsd; do
        if dpkg -l | grep -q "^ii  $pkg"; then
            log_ok "$pkg"
            echo "- [x] $pkg" >> "$CHECKFILE"
        else
            log_miss "$pkg"
            echo "- [ ] $pkg" >> "$CHECKFILE"
        fi
    done
    echo "" >> "$CHECKFILE"

    # APT packages
    echo "## APT Packages" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"

    INSTALLED=0
    MISSING=0

    for category in base shells editors network graphics wayland browsers monitors dev utils cli_tools gui_apps; do
        PKGS=$(jq -r ".apt.$category // [] | .[]" "$CONFIG" 2>/dev/null)
        if [ -n "$PKGS" ]; then
            echo "### $category" >> "$CHECKFILE"
            for pkg in $PKGS; do
                if dpkg -l | grep -q "^ii  $pkg"; then
                    log_ok "$pkg"
                    echo "- [x] $pkg" >> "$CHECKFILE"
                    INSTALLED=$((INSTALLED + 1))
                else
                    log_miss "$pkg"
                    echo "- [ ] $pkg" >> "$CHECKFILE"
                    MISSING=$((MISSING + 1))
                fi
            done
            echo "" >> "$CHECKFILE"
        fi
    done

    # Kali tools
    echo "## Kali Security Tools" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"

    KALI_PKGS=$(jq -r '.apt.kali_tools // [] | .[]' "$CONFIG" 2>/dev/null)
    for pkg in $KALI_PKGS; do
        if dpkg -l | grep -q "^ii  $pkg"; then
            log_ok "$pkg (kali)"
            echo "- [x] $pkg" >> "$CHECKFILE"
        else
            log_miss "$pkg (kali)"
            echo "- [ ] $pkg" >> "$CHECKFILE"
            MISSING=$((MISSING + 1))
        fi
    done
    echo "" >> "$CHECKFILE"

    # NPM packages
    echo "## NPM Packages" >> "$CHECKFILE"
    echo "" >> "$CHECKFILE"

    NPM_PKGS=$(jq -r '.npm.global // [] | .[]' "$CONFIG" 2>/dev/null)
    for pkg in $NPM_PKGS; do
        if npm list -g "$pkg" &>/dev/null; then
            log_ok "$pkg (npm)"
            echo "- [x] $pkg" >> "$CHECKFILE"
        else
            log_miss "$pkg (npm)"
            echo "- [ ] $pkg" >> "$CHECKFILE"
            MISSING=$((MISSING + 1))
        fi
    done

    # Summary
    echo "" >> "$CHECKFILE"
    echo "---" >> "$CHECKFILE"
    echo "## Summary" >> "$CHECKFILE"
    echo "- Installed: $INSTALLED" >> "$CHECKFILE"
    echo "- Missing: $MISSING" >> "$CHECKFILE"

    log_head "Scan Complete"
    log_info "Installed: $INSTALLED"
    log_info "Missing: $MISSING"
    log_info "Details: $CHECKFILE"
}

###################
# INSTALL COMMAND
###################

cmd_install() {
    check_jq
    check_config

    log_head "Installing Base Packages"

    # Update first
    log_info "Updating package lists..."
    $SUDO apt-get update

    # All apt packages (except kali_tools)
    ALL_PKGS=""
    for category in base shells editors network graphics wayland browsers monitors dev utils cli_tools gui_apps; do
        PKGS=$(jq -r ".apt.$category // [] | .[]" "$CONFIG" 2>/dev/null)
        ALL_PKGS="$ALL_PKGS $PKGS"
    done

    log_info "Installing apt packages..."
    $SUDO apt-get install -y $ALL_PKGS || {
        log_info "Some packages failed, trying individually..."
        for pkg in $ALL_PKGS; do
            $SUDO apt-get install -y "$pkg" 2>/dev/null || log_info "Skipped: $pkg"
        done
    }

    # NPM packages
    NPM_PKGS=$(jq -r '.npm.global // [] | .[]' "$CONFIG" 2>/dev/null)
    if [ -n "$NPM_PKGS" ] && command -v npm &>/dev/null; then
        log_info "Installing npm packages..."
        for pkg in $NPM_PKGS; do
            $SUDO npm install -g "$pkg" 2>/dev/null || log_info "npm: $pkg failed"
        done
    fi

    # Enable services
    log_info "Enabling services..."
    SERVICES=$(jq -r '.services.enable // [] | .[]' "$CONFIG" 2>/dev/null)
    for svc in $SERVICES; do
        $SUDO systemctl enable "$svc" 2>/dev/null || true
        $SUDO systemctl start "$svc" 2>/dev/null || true
        log_ok "Service: $svc"
    done

    # Create mount points
    log_info "Creating mount points..."
    $SUDO mkdir -p /mnt/pool /mnt/shared-lib

    # Passwordless sudo for user
    if [ -n "$USER" ] && [ "$USER" != "root" ]; then
        if ! grep -q "$USER.*NOPASSWD" /etc/sudoers.d/* 2>/dev/null; then
            echo "$USER ALL=(ALL) NOPASSWD: ALL" | $SUDO tee /etc/sudoers.d/$USER > /dev/null
            log_ok "Passwordless sudo enabled for $USER"
        fi
    fi

    # Create .xinitrc
    if [ ! -f ~/.xinitrc ]; then
        echo "exec openbox-session" > ~/.xinitrc
        log_ok "Created ~/.xinitrc"
    fi

    # Log
    echo "- $(date '+%Y-%m-%d %H:%M'): Base install completed" >> "$LOGFILE"

    log_head "Base Install Complete"
    log_info "Run: ./install.sh kali  # For security tools"
}

###################
# KALI TOOLS COMMAND
###################

cmd_kali() {
    check_jq
    check_config

    log_head "Installing Kali Security Tools"

    log_info "This may take a while..."

    # Kali core first
    log_info "Installing kali-linux-core..."
    $SUDO apt-get install -y kali-linux-core || log_info "kali-linux-core skipped"

    # Individual tools
    KALI_PKGS=$(jq -r '.apt.kali_tools // [] | .[]' "$CONFIG" 2>/dev/null)

    log_info "Installing security tools..."
    for pkg in $KALI_PKGS; do
        log_info "Installing $pkg..."
        $SUDO apt-get install -y "$pkg" 2>/dev/null || log_info "Skipped: $pkg"
    done

    # Log
    echo "- $(date '+%Y-%m-%d %H:%M'): Kali tools installed" >> "$LOGFILE"

    log_head "Kali Tools Install Complete"
    log_info "Tools installed: nmap, wireshark, metasploit, etc."
}

###################
# WEBSERVER COMMAND
###################

cmd_webserver() {
    log_head "Deploying http-dev (Markdown + Eruda file server)"

    DOTFILES="$SCRIPT_DIR/dotfiles"

    # Deploy server + libs
    mkdir -p ~/.local/bin ~/.local/lib/httpd
    cp "$DOTFILES/web-server-md-eruda.mjs" ~/.local/bin/
    cp "$DOTFILES/httpd-lib/marked.min.js"           ~/.local/lib/httpd/
    cp "$DOTFILES/httpd-lib/github-markdown-dark.css" ~/.local/lib/httpd/
    cp "$DOTFILES/httpd-lib/browse.html"              ~/.local/lib/httpd/
    chmod +x ~/.local/bin/web-server-md-eruda.mjs
    log_ok "Server assets deployed to ~/.local/bin + ~/.local/lib/httpd"

    # Deploy http-dev wrapper
    cat > ~/.local/bin/http-dev <<'WRAPPER'
#!/bin/sh
# http-dev — POSIX wrapper for web-server-md-eruda.mjs
# Usage: http-dev [start|stop|status|restart] [port] [dir]

PORT="${2:-8000}"
DIR="${3:-$HOME}"
PID_FILE="$HOME/.cache/web-server-md-eruda.pid"
SERVER="$HOME/.local/bin/web-server-md-eruda.mjs"

is_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

do_start() {
  if is_running; then
    pid=$(cat "$PID_FILE")
    echo "already running (PID $pid) on http://127.0.0.1:$PORT"
    return 0
  fi
  mkdir -p "$(dirname "$PID_FILE")"
  node "$SERVER" "$PORT" "$DIR" >/dev/null 2>&1 &
  pid=$!
  echo "$pid" > "$PID_FILE"
  echo "started (PID $pid) on http://127.0.0.1:$PORT"
}

do_stop() {
  if is_running; then
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null
    rm -f "$PID_FILE"
    echo "stopped (was PID $pid)"
  else
    rm -f "$PID_FILE"
    echo "not running"
  fi
}

do_status() {
  if is_running; then
    pid=$(cat "$PID_FILE")
    echo "running (PID $pid) on http://127.0.0.1:$PORT"
  else
    rm -f "$PID_FILE"
    echo "not running"
  fi
}

case "${1:-start}" in
  start)   do_start ;;
  stop)    do_stop ;;
  status)  do_status ;;
  restart) do_stop; do_start ;;
  *)       echo "Usage: http-dev {start|stop|status|restart} [port] [dir]"; exit 1 ;;
esac
WRAPPER
    chmod +x ~/.local/bin/http-dev
    log_ok "http-dev wrapper deployed to ~/.local/bin/http-dev"

    # Systemd user service
    mkdir -p ~/.config/systemd/user
    cat > ~/.config/systemd/user/http-dev.service <<EOF
[Unit]
Description=http-dev — Node.js file server (Markdown + Eruda)

[Service]
ExecStart=$(which node) %h/.local/bin/web-server-md-eruda.mjs 8000 %h
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now http-dev.service
    log_ok "http-dev systemd user service enabled and started"

    echo ""
    log_info "Access at: http://127.0.0.1:8000"
    log_info "Control:   http-dev start|stop|status|restart [port] [dir]"

    echo "- $(date '+%Y-%m-%d %H:%M'): http-dev webserver deployed" >> "$LOGFILE"
}

###################
# DESKTOP COMMANDS
###################

cmd_desktop() {
    log_head "Starting Openbox Desktop"
    if [ ! -f ~/.xinitrc ]; then
        echo "exec openbox-session" > ~/.xinitrc
    fi
    startx
}

cmd_sway() {
    log_head "Starting Sway (Wayland)"
    sway
}

###################
# FSTAB / MOUNTS / SWAP — DECLARATIVE SYNC FROM install.json
###################
#
# Reads .mounts.* and .swap from install.json (the source of truth) and
# regenerates /etc/fstab + /etc/crypttab + swapfile to match. Idempotent.
# Backs up the previous files with timestamp before any write.
#
# After the 2026-05-15 incident the Kali fstab still had `/mnt/kubuntu` even
# though install.json was updated to `/mnt/shared-lib` — because nothing
# applied the declarative state. This function closes that gap.
#
# Verbose: every action is logged. Any error trips the top-level ERR trap.

cmd_fstab() {
    log_head "Sync /etc/fstab + /etc/crypttab from install.json"
    check_jq
    check_config

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local new_fstab=/tmp/install-fstab.new.$$
    local new_crypt=/tmp/install-crypttab.new.$$

    # ── fstab ─────────────────────────────────────────────────────────────
    # Always preserve the ROOT (/) entry — that's the system's own fstab
    # line, never managed by install.json.
    log_info "Preserving root entry from current /etc/fstab"
    if [ -f /etc/fstab ]; then
        grep -E '\s/(\s)' /etc/fstab > "$new_fstab" || true
    fi

    # Append every entry from install.json mounts.*
    jq -r '
      .mounts | to_entries[] |
      "\(.value.device)\t\(.value.mountpoint)\t\(.value.fstype)\t\(.value.options)\t0\t0"
    ' "$CONFIG" >> "$new_fstab"

    # Append swap (separate top-level key)
    local swap_entry
    swap_entry="$(jq -r '.swap.fstab_entry // empty' "$CONFIG")"
    if [ -n "$swap_entry" ]; then
        log_info "Appending swap entry"
        echo "$swap_entry" >> "$new_fstab"
    fi

    log_info "New /etc/fstab content:"
    sed 's/^/  /' "$new_fstab"

    if [ -f /etc/fstab ] && ! cmp -s "$new_fstab" /etc/fstab; then
        $SUDO cp /etc/fstab "/etc/fstab.bak.$ts"
        log_ok "Backed up old /etc/fstab → /etc/fstab.bak.$ts"
        $SUDO cp "$new_fstab" /etc/fstab
        log_ok "Wrote new /etc/fstab"
    elif [ ! -f /etc/fstab ]; then
        $SUDO cp "$new_fstab" /etc/fstab
        log_ok "Wrote /etc/fstab (no prior file)"
    else
        log_ok "/etc/fstab already in sync — no change"
    fi
    rm -f "$new_fstab"

    # ── crypttab ──────────────────────────────────────────────────────────
    # One crypttab line per mount with .luks_name set.
    jq -r '
      .mounts | to_entries[] | select(.value.luks_name != null) |
      "\(.value.luks_name)\t\(.value.device)\tnone\tluks,noauto"
    ' "$CONFIG" > "$new_crypt"

    if [ -s "$new_crypt" ]; then
        log_info "New /etc/crypttab content:"
        sed 's/^/  /' "$new_crypt"
        if [ -f /etc/crypttab ] && ! cmp -s "$new_crypt" /etc/crypttab; then
            $SUDO cp /etc/crypttab "/etc/crypttab.bak.$ts"
            log_ok "Backed up old /etc/crypttab → /etc/crypttab.bak.$ts"
            $SUDO cp "$new_crypt" /etc/crypttab
            log_ok "Wrote new /etc/crypttab"
        elif [ ! -f /etc/crypttab ]; then
            $SUDO cp "$new_crypt" /etc/crypttab
            log_ok "Wrote /etc/crypttab (no prior file)"
        else
            log_ok "/etc/crypttab already in sync — no change"
        fi
    else
        log_info "No LUKS mounts declared → /etc/crypttab not touched"
    fi
    rm -f "$new_crypt"

    # ── swap file (only if declared and missing) ──────────────────────────
    local swap_file swap_size swap_label
    swap_file="$(jq -r '.swap.swapfile // empty' "$CONFIG")"
    swap_size="$(jq -r '.swap.size_gib // empty' "$CONFIG")"
    swap_label="$(jq -r '.swap.label // empty' "$CONFIG")"
    if [ -n "$swap_file" ] && [ ! -f "$swap_file" ]; then
        log_info "Swap file $swap_file missing — creating ${swap_size}G with label '$swap_label'"
        $SUDO fallocate -l "${swap_size}G" "$swap_file"
        $SUDO chmod 0600 "$swap_file"
        $SUDO mkswap -L "$swap_label" "$swap_file"
        log_ok "Swap file created"
    elif [ -n "$swap_file" ]; then
        log_ok "Swap file $swap_file already exists"
    fi

    # ── reload systemd + activate ─────────────────────────────────────────
    $SUDO systemctl daemon-reload 2>&1 | sed 's/^/  /'
    log_ok "systemd daemon-reload done"

    # Try to mount every fstab entry that's not currently mounted (noauto OK).
    log_info "Verifying mountability (noauto entries skipped — they don't auto-mount)"
    jq -r '.mounts[] | select((.options // "") | contains("noauto") | not) | .mountpoint' "$CONFIG" | while read -r mp; do
        if mountpoint -q "$mp"; then
            log_ok "  $mp already mounted"
        else
            log_info "  mounting $mp"
            $SUDO mount "$mp" 2>&1 | sed 's/^/    /' || log_info "  $mp mount returned non-zero (may be noauto or LUKS-locked)"
        fi
    done

    echo "- $(date '+%Y-%m-%d %H:%M'): fstab/crypttab/swap synced from install.json" >> "$LOGFILE"
    log_ok "cmd_fstab: complete"
}

###################
# MAIN
###################

case "${1:-help}" in
    surface)    cmd_surface ;;
    scan)       cmd_scan ;;
    install)    cmd_install ;;
    kali)       cmd_kali ;;
    webserver)  cmd_webserver ;;
    desktop)    cmd_desktop ;;
    sway)       cmd_sway ;;
    fstab)      cmd_fstab ;;
    help|*)     usage ;;
esac
