#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# Surface Pro Dual Profile - Configuration Injection Script
# ═══════════════════════════════════════════════════════════════════════════
#
# Usage: ./inject.sh [OPTIONS]
#
# Options:
#   --config FILE    Path to config.json (default: ./config.json)
#   --target DIR     Target root filesystem (default: /)
#   --profile NAME   Profile to configure: anon|auth|both (default: both)
#   --distro NAME    Distribution: fedora|arch (auto-detected if not set)
#   --dry-run        Show what would be done without making changes
#   --users          Only configure users
#   --ssh            Only configure SSH
#   --surface        Only install Surface drivers
#   --autologin      Only configure auto-login
#   --podman         Only configure Podman
#   --dotfiles       Only inject dotfiles
#   --all            Apply all configurations (default)
#   --help           Show this help message
#
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Defaults
CONFIG_FILE="./config.json"
TARGET_ROOT="/"
PROFILE="both"
DISTRO=""
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Actions
DO_USERS=false
DO_SSH=false
DO_SURFACE=false
DO_AUTOLOGIN=false
DO_PODMAN=false
DO_DOTFILES=false
DO_ALL=true

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

run_cmd() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

get_json() {
    jq -r "$1" "$CONFIG_FILE"
}

get_json_array() {
    jq -r "$1 | .[]" "$CONFIG_FILE"
}

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            fedora|kinoite) echo "fedora" ;;
            arch|archlinux|endeavouros) echo "arch" ;;
            *) echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ] && [ "$TARGET_ROOT" = "/" ]; then
        log_error "This script must be run as root (or use --target for chroot)"
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Parse Arguments
# ═══════════════════════════════════════════════════════════════════════════

while [[ $# -gt 0 ]]; do
    case $1 in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --target) TARGET_ROOT="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --distro) DISTRO="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --users) DO_USERS=true; DO_ALL=false; shift ;;
        --ssh) DO_SSH=true; DO_ALL=false; shift ;;
        --surface) DO_SURFACE=true; DO_ALL=false; shift ;;
        --autologin) DO_AUTOLOGIN=true; DO_ALL=false; shift ;;
        --podman) DO_PODMAN=true; DO_ALL=false; shift ;;
        --dotfiles) DO_DOTFILES=true; DO_ALL=false; shift ;;
        --all) DO_ALL=true; shift ;;
        --help)
            head -30 "$0" | tail -25
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# ═══════════════════════════════════════════════════════════════════════════
# Validation
# ═══════════════════════════════════════════════════════════════════════════

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Config file not found: $CONFIG_FILE"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_error "jq is required but not installed"
    exit 1
fi

if [ -z "$DISTRO" ]; then
    DISTRO=$(detect_distro)
    log_info "Detected distro: $DISTRO"
fi

if [ "$DISTRO" = "unknown" ]; then
    log_error "Unknown distribution. Use --distro to specify."
    exit 1
fi

check_root

log_info "Configuration: $CONFIG_FILE"
log_info "Target root: $TARGET_ROOT"
log_info "Profile: $PROFILE"
log_info "Distro: $DISTRO"
log_info "Dry run: $DRY_RUN"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# User Configuration
# ═══════════════════════════════════════════════════════════════════════════

configure_users() {
    log_info "═══ Configuring Users ═══"

    for user in $(jq -r '.users | keys[]' "$CONFIG_FILE"); do
        log_info "Creating user: $user"

        local uid=$(get_json ".users.$user.uid")
        local gid=$(get_json ".users.$user.gid")
        local shell=$(get_json ".users.$user.shell")
        local password=$(get_json ".users.$user.password")
        local sudo=$(get_json ".users.$user.sudo")
        local sudo_nopasswd=$(get_json ".users.$user.sudo_nopasswd // false")
        local groups=$(jq -r ".users.$user.groups | join(\",\")" "$CONFIG_FILE")

        # Create user
        if ! id "$user" &>/dev/null; then
            run_cmd useradd -m -u "$uid" -s "$shell" "$user"
            log_success "Created user $user"
        else
            log_warn "User $user already exists"
        fi

        # Set password
        if [ -n "$password" ] && [ "$password" != "null" ]; then
            run_cmd bash -c "echo '$user:$password' | chpasswd"
            log_success "Set password for $user"
        fi

        # Add to groups
        if [ -n "$groups" ] && [ "$groups" != "" ]; then
            for group in $(echo "$groups" | tr ',' ' '); do
                if getent group "$group" &>/dev/null; then
                    run_cmd usermod -aG "$group" "$user"
                    log_success "Added $user to group $group"
                else
                    log_warn "Group $group does not exist"
                fi
            done
        fi

        # Configure sudo
        if [ "$sudo" = "true" ] && [ "$sudo_nopasswd" = "true" ]; then
            local sudoers_file="${TARGET_ROOT}/etc/sudoers.d/$user"
            run_cmd bash -c "echo '$user ALL=(ALL) NOPASSWD: ALL' > '$sudoers_file'"
            run_cmd chmod 440 "$sudoers_file"
            log_success "Configured NOPASSWD sudo for $user"
        fi

        # Create home directories
        for dir in $(jq -r ".users.$user.home_dirs[]" "$CONFIG_FILE" 2>/dev/null); do
            local home_dir="${TARGET_ROOT}/home/$user/$dir"
            run_cmd mkdir -p "$home_dir"
            run_cmd chown "$user:$user" "$home_dir"
        done

        echo ""
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# SSH Configuration
# ═══════════════════════════════════════════════════════════════════════════

configure_ssh() {
    log_info "═══ Configuring SSH ═══"

    local sshd_config="${TARGET_ROOT}/etc/ssh/sshd_config"

    if [ ! -f "$sshd_config" ]; then
        log_warn "sshd_config not found, skipping SSH configuration"
        return
    fi

    # Backup original
    run_cmd cp "$sshd_config" "${sshd_config}.bak"

    local permit_root=$(get_json '.ssh.permit_root_login')
    local password_auth=$(get_json '.ssh.password_authentication')
    local pubkey_auth=$(get_json '.ssh.pubkey_authentication')
    local max_tries=$(get_json '.ssh.max_auth_tries')
    local empty_pass=$(get_json '.ssh.permit_empty_passwords')

    # Apply settings
    run_cmd sed -i "s/^#*PermitRootLogin.*/PermitRootLogin $permit_root/" "$sshd_config"
    run_cmd sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication $password_auth/" "$sshd_config"
    run_cmd sed -i "s/^#*PubkeyAuthentication.*/PubkeyAuthentication $pubkey_auth/" "$sshd_config"
    run_cmd sed -i "s/^#*MaxAuthTries.*/MaxAuthTries $max_tries/" "$sshd_config"
    run_cmd sed -i "s/^#*PermitEmptyPasswords.*/PermitEmptyPasswords $empty_pass/" "$sshd_config"

    log_success "SSH configured"

    # Add TODO comment
    local todo=$(get_json '.ssh.password_authentication_todo // empty')
    if [ -n "$todo" ]; then
        log_warn "TODO: $todo"
    fi

    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# Surface Drivers
# ═══════════════════════════════════════════════════════════════════════════

configure_surface() {
    log_info "═══ Installing Surface Drivers ═══"

    case "$DISTRO" in
        fedora)
            local repo_url=$(get_json '.surface.repos.fedora.url')
            local key_url=$(get_json '.surface.repos.fedora.key')

            log_info "Adding linux-surface repository..."
            run_cmd wget -O "${TARGET_ROOT}/etc/yum.repos.d/linux-surface.repo" "$repo_url"
            run_cmd rpm --import "$key_url"

            log_info "Installing Surface packages..."
            for pkg in $(get_json_array '.surface.packages.fedora'); do
                run_cmd rpm-ostree install "$pkg" || log_warn "Failed to install $pkg"
            done
            ;;
        arch)
            local server=$(get_json '.surface.repos.arch.server')
            local key_url=$(get_json '.surface.repos.arch.key')
            local key_id=$(get_json '.surface.repos.arch.key_id')

            log_info "Adding linux-surface repository..."
            if ! grep -q "\[linux-surface\]" "${TARGET_ROOT}/etc/pacman.conf"; then
                run_cmd bash -c "echo -e '\n[linux-surface]\nServer = $server' >> '${TARGET_ROOT}/etc/pacman.conf'"
            fi

            run_cmd bash -c "curl -s '$key_url' | pacman-key --add -"
            run_cmd pacman-key --lsign-key "$key_id"

            log_info "Installing Surface packages..."
            run_cmd pacman -Syu --noconfirm
            for pkg in $(get_json_array '.surface.packages.arch'); do
                run_cmd pacman -S --noconfirm "$pkg" || log_warn "Failed to install $pkg"
            done
            ;;
    esac

    # Enable services
    for service in $(get_json_array '.surface.services'); do
        run_cmd systemctl enable "$service"
        log_success "Enabled service: $service"
    done

    log_success "Surface drivers configured"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# Auto-Login Configuration
# ═══════════════════════════════════════════════════════════════════════════

configure_autologin() {
    log_info "═══ Configuring Auto-Login ═══"

    local user
    if [ "$PROFILE" = "anon" ]; then
        user=$(get_json '.profiles.anon.auto_login_user')
    else
        user=$(get_json '.profiles.auth.auto_login_user')
    fi

    # KDE (SDDM)
    local kde_config=$(get_json '.auto_login.kde.config_path')
    local kde_session=$(get_json '.auto_login.kde.session')
    local kde_dir=$(dirname "${TARGET_ROOT}${kde_config}")

    run_cmd mkdir -p "$kde_dir"
    run_cmd bash -c "cat > '${TARGET_ROOT}${kde_config}' << EOF
[Autologin]
User=$user
Session=$kde_session
EOF"
    log_success "SDDM auto-login configured for $user"

    # Light (getty)
    local getty_config=$(get_json '.auto_login.light.config_path')
    local getty_dir=$(dirname "${TARGET_ROOT}${getty_config}")

    run_cmd mkdir -p "$getty_dir"
    run_cmd bash -c "cat > '${TARGET_ROOT}${getty_config}' << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $user --noclear %I \$TERM
EOF"
    log_success "Getty auto-login configured for $user"

    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# Podman Configuration
# ═══════════════════════════════════════════════════════════════════════════

configure_podman() {
    log_info "═══ Configuring Podman ═══"

    local enable_linger=$(get_json '.podman.enable_linger')

    for user in $(jq -r '.users | keys[]' "$CONFIG_FILE"); do
        if [ "$enable_linger" = "true" ]; then
            run_cmd loginctl enable-linger "$user"
            log_success "Enabled linger for $user (rootless containers)"
        fi
    done

    log_success "Podman configured"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# Dotfiles Injection
# ═══════════════════════════════════════════════════════════════════════════

configure_dotfiles() {
    log_info "═══ Injecting Dotfiles ═══"

    local source_dir="${SCRIPT_DIR}/$(get_json '.dotfiles.source_dir')"

    if [ ! -d "$source_dir" ]; then
        log_warn "Dotfiles source directory not found: $source_dir"
        return
    fi

    for user in $(jq -r '.users | keys[]' "$CONFIG_FILE"); do
        local home_dir="${TARGET_ROOT}/home/$user"

        for dest in $(jq -r '.dotfiles.files | keys[]' "$CONFIG_FILE"); do
            local src=$(get_json ".dotfiles.files.\"$dest\"")
            local src_path="${source_dir}/${src}"
            local dest_path="${home_dir}/${dest}"

            if [ -f "$src_path" ]; then
                local dest_dir=$(dirname "$dest_path")
                run_cmd mkdir -p "$dest_dir"
                run_cmd cp "$src_path" "$dest_path"
                run_cmd chown "$user:$user" "$dest_path"
                log_success "Copied $src to $dest for $user"
            else
                log_warn "Dotfile not found: $src_path"
            fi
        done
    done

    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# Security Configuration
# ═══════════════════════════════════════════════════════════════════════════

configure_security() {
    log_info "═══ Configuring Security Settings ═══"

    # Volatile journal
    local journal_storage=$(get_json '.security.journal.storage')
    local journal_dir="${TARGET_ROOT}/etc/systemd/journald.conf.d"
    run_cmd mkdir -p "$journal_dir"
    run_cmd bash -c "echo '[Journal]
Storage=$journal_storage' > '$journal_dir/volatile.conf'"
    log_success "Journal set to $journal_storage"

    # tmpfs
    for mount in $(jq -r '.security.tmpfs | keys[]' "$CONFIG_FILE"); do
        local size=$(get_json ".security.tmpfs.\"$mount\".size")
        local mode=$(get_json ".security.tmpfs.\"$mount\".mode")
        log_info "tmpfs $mount: size=$size, mode=$mode (add to fstab manually)"
    done

    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════

main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║          Surface Pro Dual Profile - Configuration Injection               ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo ""

    if $DO_ALL || $DO_USERS; then configure_users; fi
    if $DO_ALL || $DO_SSH; then configure_ssh; fi
    if $DO_ALL || $DO_SURFACE; then configure_surface; fi
    if $DO_ALL || $DO_AUTOLOGIN; then configure_autologin; fi
    if $DO_ALL || $DO_PODMAN; then configure_podman; fi
    if $DO_ALL || $DO_DOTFILES; then configure_dotfiles; fi
    if $DO_ALL; then configure_security; fi

    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                        Configuration Complete!                             ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo ""

    if $DRY_RUN; then
        log_warn "This was a dry run. No changes were made."
    fi
}

main
