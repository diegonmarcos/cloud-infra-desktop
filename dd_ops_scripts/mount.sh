#!/bin/sh
# FUSE Mount Manager - Unified mount manager for VMs, Drives, and Phones
# Author: Diego Nepomuceno Marcos
# Version: 1.1

set -e

FUSE_DIR="/home/diego/mnt_mnt"
CONFIG_FILE="$FUSE_DIR/mount.json"
LOG_FILE="$FUSE_DIR/.mount.log"
RCLONE_OPTS="--vfs-cache-mode writes"

# ==============================================================================
# LOGGING
# ==============================================================================

init_log() {
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE"
    fi
    # Rotate log if > 1MB
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        touch "$LOG_FILE"
    fi
}

log_debug() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

log_error() {
    printf "[%s] ERROR: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

init_log

# ==============================================================================
# JSON CONFIG HELPERS
# ==============================================================================

check_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required. Install: sudo pacman -S jq"
        exit 1
    fi
}

# Get phone config from JSON
get_phone_config() {
    key="$1"
    check_jq
    jq -r ".[\"_phone\"].$key // empty" "$CONFIG_FILE" 2>/dev/null
}

# Get OCI Flex config from JSON
get_oci_flex_config() {
    key="$1"
    check_jq
    jq -r ".[\"_oci_flex\"].$key // empty" "$CONFIG_FILE" 2>/dev/null
}

# List enabled mounts by type
list_mounts() {
    mount_type="$1"
    check_jq
    jq -r ".[] | select(.type == \"$mount_type\" and .enabled == true) | .name" "$CONFIG_FILE" 2>/dev/null
}

# Get mount remote name
get_mount_remote() {
    name="$1"
    check_jq
    jq -r ".[] | select(.name == \"$name\") | .remote" "$CONFIG_FILE" 2>/dev/null
}

# Get all mounts (for status display)
list_all_mounts() {
    check_jq
    jq -r '.[] | select(has("name") and has("type")) | "\(.name)|\(.type)|\(.enabled)"' "$CONFIG_FILE" 2>/dev/null
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# Unicode symbols
SYM_CHECK="✓"
SYM_CROSS="✗"
SYM_DOT="●"
SYM_CIRCLE="○"
SYM_ARROW="→"
SYM_WARN="⚠"

# ==============================================================================
# HELPERS
# ==============================================================================

print_header() {
    printf "\n${CYAN}${BOLD}%s${NC}\n" "$1"
    printf "%s\n" "$(echo "$1" | sed 's/./-/g')"
}

log() { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[-]${NC} %s\n" "$1"; }

is_mounted() {
    mountpoint -q "$1" 2>/dev/null
}

# ==============================================================================
# RCLONE MOUNTS (VMs & Drives)
# ==============================================================================

check_rclone_remote() {
    remote=$1
    rclone listremotes 2>/dev/null | grep -q "^${remote}:$"
}

# Create a new rclone remote interactively
create_rclone_remote() {
    remote=$1
    remote_type=$2  # "drive" for Google Drive, "sftp" for SSH

    printf "\n${CYAN}${BOLD}Creating rclone remote: %s${NC}\n" "$remote"
    log_debug "Creating rclone remote: $remote (type: $remote_type)"

    case "$remote_type" in
        drive)
            printf "${YELLOW}This will open a browser for Google OAuth.${NC}\n"
            printf "Press Enter to continue or Ctrl+C to cancel..."
            read -r _

            # Use rclone config create with interactive OAuth
            rclone config create "$remote" drive \
                scope=drive \
                --config="$HOME/.config/rclone/rclone.conf"

            if check_rclone_remote "$remote"; then
                log "Remote '$remote' created successfully!"
                log_debug "Remote $remote created successfully"
                return 0
            else
                error "Failed to create remote '$remote'"
                log_error "Failed to create remote $remote"
                return 1
            fi
            ;;
        sftp)
            printf "Enter SSH host: "
            read -r ssh_host
            printf "Enter SSH user: "
            read -r ssh_user
            printf "Enter SSH key path (or leave empty for password): "
            read -r ssh_key

            if [ -n "$ssh_key" ]; then
                rclone config create "$remote" sftp \
                    host="$ssh_host" \
                    user="$ssh_user" \
                    key_file="$ssh_key"
            else
                rclone config create "$remote" sftp \
                    host="$ssh_host" \
                    user="$ssh_user"
            fi

            if check_rclone_remote "$remote"; then
                log "Remote '$remote' created successfully!"
                return 0
            else
                error "Failed to create remote '$remote'"
                return 1
            fi
            ;;
        *)
            error "Unknown remote type: $remote_type"
            return 1
            ;;
    esac
}

# Prompt to create missing remote
prompt_create_remote() {
    remote=$1

    # Determine type based on remote name
    case "$remote" in
        Gdrive_*) remote_type="drive" ;;
        OCI_*|GCP_*) remote_type="sftp" ;;
        *) remote_type="unknown" ;;
    esac

    printf "\n${YELLOW}Remote '%s' is not configured.${NC}\n" "$remote"
    printf "Would you like to create it now? [y/N] "
    read -r answer

    case "$answer" in
        [Yy]|[Yy][Ee][Ss])
            create_rclone_remote "$remote" "$remote_type"
            return $?
            ;;
        *)
            warn "Skipping remote creation"
            return 1
            ;;
    esac
}

mount_rclone_path() {
    remote=$1
    remote_path=$2
    mountpoint=$3

    log_debug "Attempting mount: ${remote}:${remote_path} -> $mountpoint"

    if is_mounted "$mountpoint"; then
        warn "Already mounted: $mountpoint"
        log_debug "Skip: $mountpoint already mounted"
        return 0
    fi

    # Check if rclone remote exists, offer to create if missing
    if ! check_rclone_remote "$remote"; then
        log_error "Remote '$remote' not found"
        if prompt_create_remote "$remote"; then
            log_debug "Remote $remote created, continuing with mount"
        else
            return 1
        fi
    fi

    mkdir -p "$mountpoint"

    # Capture rclone errors to log
    mount_log=$(mktemp)
    # shellcheck disable=SC2086
    nohup rclone mount "${remote}:${remote_path}" "$mountpoint" $RCLONE_OPTS >"$mount_log" 2>&1 &
    mount_pid=$!

    tries=0
    while [ "$tries" -lt 10 ]; do
        sleep 0.5
        if is_mounted "$mountpoint"; then
            log "Mounted ${remote}:${remote_path} -> $mountpoint"
            log_debug "Success: ${remote}:${remote_path} -> $mountpoint (pid=$mount_pid)"
            rm -f "$mount_log"
            return 0
        fi
        # Check if process died
        if ! kill -0 "$mount_pid" 2>/dev/null; then
            break
        fi
        tries=$((tries + 1))
    done

    # Mount failed - capture error
    if [ -f "$mount_log" ] && [ -s "$mount_log" ]; then
        err_msg=$(cat "$mount_log")
        log_error "Mount failed: ${remote}:${remote_path} - $err_msg"
    else
        log_error "Mount failed: ${remote}:${remote_path} - timeout or unknown error"
    fi
    rm -f "$mount_log"

    error "Failed: ${remote}:${remote_path}"
    return 1
}

mount_vm() {
    name=$1
    remote=$2

    log "Mounting $name..."
    mount_rclone_path "$remote" "/" "$FUSE_DIR/$name/sys" || true
    mount_rclone_path "$remote" "/home" "$FUSE_DIR/$name/home" || true
    mount_rclone_path "$remote" "/var/lib/docker/volumes" "$FUSE_DIR/$name/docker" || true
    mount_rclone_path "$remote" "/mnt" "$FUSE_DIR/$name/mnt" || true
}

unmount_vm() {
    name=$1
    for subdir in sys home docker mnt; do
        if is_mounted "$FUSE_DIR/$name/$subdir"; then
            fusermount -uz "$FUSE_DIR/$name/$subdir" 2>/dev/null
            log "Unmounted $name/$subdir"
        fi
    done
}

mount_drive() {
    name=$1
    remote=$2

    log "Mounting $name..."
    mount_rclone_path "$remote" "/" "$FUSE_DIR/$name" || true
}

unmount_drive() {
    name=$1
    if is_mounted "$FUSE_DIR/$name"; then
        fusermount -uz "$FUSE_DIR/$name" 2>/dev/null
        log "Unmounted $name"
    fi
}

# ==============================================================================
# PHONE MOUNT (KDE Connect)
# ==============================================================================

phone_is_reachable() {
    device_id=$(get_phone_config "device_id")
    [ -z "$device_id" ] && return 1
    kdeconnect-cli -d "$device_id" --ping >/dev/null 2>&1
}

phone_is_mounted() {
    device_id=$(get_phone_config "device_id")
    [ -z "$device_id" ] && return 1
    qdbus org.kde.kdeconnect "/modules/kdeconnect/devices/$device_id/sftp" \
        org.kde.kdeconnect.device.sftp.isMounted 2>/dev/null | grep -q true
}

mount_phone() {
    device_id=$(get_phone_config "device_id")
    phone_name=$(get_phone_config "name")
    sftp_base=$(get_phone_config "sftp_base")

    if [ -z "$device_id" ]; then
        error "Phone not configured in mount.json"
        return 1
    fi

    if ! phone_is_reachable; then
        error "Phone not reachable. Check:"
        printf "  - Phone is on same network\n"
        printf "  - KDE Connect app is running\n"
        return 1
    fi

    log "Mounting phone via KDE Connect..."
    qdbus org.kde.kdeconnect "/modules/kdeconnect/devices/$device_id/sftp" \
        org.kde.kdeconnect.device.sftp.mount 2>/dev/null
    sleep 1

    if ! phone_is_mounted; then
        error "Failed to mount phone SFTP"
        qdbus org.kde.kdeconnect "/modules/kdeconnect/devices/$device_id/sftp" \
            org.kde.kdeconnect.device.sftp.getMountError 2>/dev/null
        return 1
    fi

    rm -f "$FUSE_DIR/$phone_name" 2>/dev/null
    ln -sf "$sftp_base" "$FUSE_DIR/$phone_name"
    log "Mounted: $FUSE_DIR/$phone_name"
}

unmount_phone() {
    device_id=$(get_phone_config "device_id")
    phone_name=$(get_phone_config "name")

    if phone_is_mounted; then
        qdbus org.kde.kdeconnect "/modules/kdeconnect/devices/$device_id/sftp" \
            org.kde.kdeconnect.device.sftp.unmount 2>/dev/null
        log "Unmounted phone"
    fi
    rm -f "$FUSE_DIR/$phone_name" 2>/dev/null
}

# ==============================================================================
# OCI FLEX CONTROL
# ==============================================================================

flex_status() {
    instance_id=$(get_oci_flex_config "instance_id")
    region=$(get_oci_flex_config "region")

    if [ -z "$instance_id" ]; then
        error "OCI Flex not configured in mount.json"
        return 1
    fi

    log "Checking OCI Flex status..."
    state=$(SUPPRESS_LABEL_WARNING=True oci compute instance get \
        --instance-id "$instance_id" \
        --region "$region" \
        --query "data.\"lifecycle-state\"" --raw-output 2>/dev/null)
    if [ -n "$state" ]; then
        case "$state" in
            RUNNING) printf "  ${GREEN}●${NC} OCI_Flex_1: %s\n" "$state" ;;
            STOPPED) printf "  ${RED}○${NC} OCI_Flex_1: %s\n" "$state" ;;
            *)       printf "  ${YELLOW}◐${NC} OCI_Flex_1: %s\n" "$state" ;;
        esac
    else
        error "Failed to get OCI Flex status"
    fi
}

flex_start() {
    instance_id=$(get_oci_flex_config "instance_id")
    region=$(get_oci_flex_config "region")

    if [ -z "$instance_id" ]; then
        error "OCI Flex not configured in mount.json"
        return 1
    fi

    log "Starting OCI Flex..."
    SUPPRESS_LABEL_WARNING=True oci compute instance action \
        --instance-id "$instance_id" \
        --region "$region" \
        --action START >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log "Start command sent. Waiting for VM..."
        sleep 5
        flex_status
    else
        error "Failed to start OCI Flex"
    fi
}

flex_stop() {
    instance_id=$(get_oci_flex_config "instance_id")
    region=$(get_oci_flex_config "region")

    if [ -z "$instance_id" ]; then
        error "OCI Flex not configured in mount.json"
        return 1
    fi

    log "Stopping OCI Flex..."
    unmount_vm "OCI_Flex_1"
    SUPPRESS_LABEL_WARNING=True oci compute instance action \
        --instance-id "$instance_id" \
        --region "$region" \
        --action STOP >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log "Stop command sent"
        flex_status
    else
        error "Failed to stop OCI Flex"
    fi
}

flex_reset() {
    instance_id=$(get_oci_flex_config "instance_id")
    region=$(get_oci_flex_config "region")

    if [ -z "$instance_id" ]; then
        error "OCI Flex not configured in mount.json"
        return 1
    fi

    log "Force resetting OCI Flex..."
    unmount_vm "OCI_Flex_1"
    SUPPRESS_LABEL_WARNING=True oci compute instance action \
        --instance-id "$instance_id" \
        --region "$region" \
        --action RESET >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log "Reset command sent. VM will reboot..."
        flex_status
    else
        error "Failed to reset OCI Flex"
    fi
}

# ==============================================================================
# BATCH OPERATIONS
# ==============================================================================

mount_all_vms() {
    print_header "Mounting VMs"
    list_mounts "vm" | while read -r name; do
        remote=$(get_mount_remote "$name")
        mount_vm "$name" "$remote"
    done
}

unmount_all_vms() {
    print_header "Unmounting VMs"
    list_mounts "vm" | while read -r name; do
        unmount_vm "$name"
    done
}

mount_all_drives() {
    print_header "Mounting Drives"
    list_mounts "drive" | while read -r name; do
        remote=$(get_mount_remote "$name")
        mount_drive "$name" "$remote"
    done
}

unmount_all_drives() {
    print_header "Unmounting Drives"
    list_mounts "drive" | while read -r name; do
        unmount_drive "$name"
    done
}

mount_all() {
    mount_all_drives
    mount_all_vms
    printf "\n"
    show_status
}

unmount_all() {
    print_header "Unmounting All"

    if is_mounted "$FUSE_DIR/Containers"; then
        fusermount -uz "$FUSE_DIR/Containers" 2>/dev/null
        log "Unmounted Containers"
    fi

    unmount_all_vms
    unmount_all_drives
    unmount_phone

    log "Done"
}

# ==============================================================================
# STATUS
# ==============================================================================

show_status() {
    printf "\n${CYAN}${BOLD}╔════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}${BOLD}║            FUSE Mount Status                   ║${NC}\n"
    printf "${CYAN}${BOLD}╚════════════════════════════════════════════════╝${NC}\n\n"

    # VMs (from JSON config)
    printf "${BLUE}${BOLD}Virtual Machines${NC}\n"
    printf "${DIM}────────────────────────────────────────────────${NC}\n"
    list_all_mounts | grep "|vm|" | while IFS='|' read -r name type enabled; do
        # Check if remote exists
        if ! check_rclone_remote "$name" 2>/dev/null; then
            printf "  ${DIM}${SYM_CROSS} %-14s${NC} ${RED}(rclone not configured)${NC}\n" "$name"
            continue
        fi
        [ "$enabled" != "true" ] && printf "  ${DIM}(disabled)${NC} "
        printf "  ${YELLOW}${BOLD}%s${NC}\n" "$name"
        for subdir in sys home docker mnt; do
            path="$FUSE_DIR/$name/$subdir"
            if [ -d "$path" ]; then
                if is_mounted "$path"; then
                    printf "    ${GREEN}${SYM_CHECK}${NC} %-8s ${DIM}%s${NC}\n" "$subdir" "$path"
                else
                    printf "    ${DIM}${SYM_CIRCLE}${NC} %-8s\n" "$subdir"
                fi
            else
                printf "    ${DIM}${SYM_CIRCLE}${NC} %-8s ${DIM}(dir missing)${NC}\n" "$subdir"
            fi
        done
    done

    # Drives (from JSON config)
    printf "\n${BLUE}${BOLD}Cloud Drives${NC}\n"
    printf "${DIM}────────────────────────────────────────────────${NC}\n"
    list_all_mounts | grep "|drive|" | while IFS='|' read -r name type enabled; do
        if ! check_rclone_remote "$name" 2>/dev/null; then
            printf "  ${RED}${SYM_CROSS}${NC} %-14s ${RED}(rclone not configured)${NC}\n" "$name"
            printf "    ${DIM}Tip: run 'rclone config' to add this remote${NC}\n"
        elif is_mounted "$FUSE_DIR/$name"; then
            printf "  ${GREEN}${SYM_CHECK}${NC} %-14s ${DIM}%s${NC}\n" "$name" "$FUSE_DIR/$name"
        else
            printf "  ${DIM}${SYM_CIRCLE}${NC} %-14s ${DIM}(not mounted)${NC}\n" "$name"
        fi
    done

    # Phone (from JSON config)
    phone_name=$(get_phone_config "name")
    sftp_base=$(get_phone_config "sftp_base")
    printf "\n${BLUE}${BOLD}Phone (KDE Connect)${NC}\n"
    printf "${DIM}────────────────────────────────────────────────${NC}\n"
    if [ -n "$phone_name" ]; then
        if phone_is_reachable 2>/dev/null; then
            if phone_is_mounted 2>/dev/null; then
                printf "  ${GREEN}${SYM_DOT}${NC} %-14s ${GREEN}connected${NC}\n" "$phone_name"
                printf "    ${DIM}${SYM_ARROW} %s${NC}\n" "$sftp_base"
            else
                printf "  ${YELLOW}${SYM_CIRCLE}${NC} %-14s ${YELLOW}reachable${NC} (not mounted)\n" "$phone_name"
            fi
        else
            printf "  ${DIM}${SYM_CIRCLE}${NC} %-14s ${DIM}offline${NC}\n" "$phone_name"
        fi
    else
        printf "  ${DIM}${SYM_CIRCLE}${NC} (not configured in mount.json)\n"
    fi

    # Containers
    printf "\n${BLUE}${BOLD}Container Symlinks${NC}\n"
    printf "${DIM}────────────────────────────────────────────────${NC}\n"
    count=$(find "$FUSE_DIR/Containers/" -maxdepth 1 -type l 2>/dev/null | wc -l)
    printf "  ${GREEN}${SYM_CHECK}${NC} %s symlinks in %s\n" "$count" "$FUSE_DIR/Containers/"

    # Log info
    printf "\n${BLUE}${BOLD}Debug Log${NC}\n"
    printf "${DIM}────────────────────────────────────────────────${NC}\n"
    if [ -f "$LOG_FILE" ]; then
        log_lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
        log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
        last_error=$(grep -c "ERROR" "$LOG_FILE" 2>/dev/null || true)
        last_error=${last_error:-0}
        printf "  ${DIM}Path:${NC}   %s\n" "$LOG_FILE"
        printf "  ${DIM}Lines:${NC}  %s  ${DIM}Size:${NC} %s  " "$log_lines" "$log_size"
        if [ "$last_error" != "0" ] && [ -n "$last_error" ]; then
            printf "${RED}Errors: %s${NC}\n" "$last_error"
        else
            printf "${GREEN}No errors${NC}\n"
        fi
    else
        printf "  ${DIM}(No log file yet)${NC}\n"
    fi
    printf "\n"
}

# ==============================================================================
# TUI MENU
# ==============================================================================

compact_status() {
    # VMs - one line each
    printf "  ${BLUE}VMs:${NC}     "
    for vm in OCI_micro_0 OCI_micro_1 OCI_Flex_1 GCP_micro_1; do
        # Count mounted subdirs
        mounted=0
        total=0
        for subdir in sys home docker mnt; do
            path="$FUSE_DIR/$vm/$subdir"
            if [ -d "$path" ]; then
                total=$((total + 1))
                if is_mounted "$path"; then
                    mounted=$((mounted + 1))
                fi
            fi
        done
        # Short VM name
        case "$vm" in
            OCI_micro_0) short="m0" ;;
            OCI_micro_1) short="m1" ;;
            OCI_Flex_1)  short="f1" ;;
            GCP_micro_1) short="gcp" ;;
        esac
        if [ "$mounted" -eq "$total" ] && [ "$total" -gt 0 ]; then
            printf "${GREEN}${SYM_CHECK}%s${NC} " "$short"
        elif [ "$mounted" -gt 0 ]; then
            printf "${YELLOW}${SYM_WARN}%s${NC}(%d/%d) " "$short" "$mounted" "$total"
        else
            printf "${DIM}${SYM_CIRCLE}%s${NC} " "$short"
        fi
    done
    printf "\n"

    # Drives - one line
    printf "  ${BLUE}Drives:${NC}  "
    for drive in Gdrive_dnm Gdrive_me; do
        case "$drive" in
            Gdrive_dnm) short="dnm" ;;
            Gdrive_me)  short="me" ;;
        esac
        if [ -d "$FUSE_DIR/$drive" ] && is_mounted "$FUSE_DIR/$drive"; then
            printf "${GREEN}${SYM_CHECK}%s${NC} " "$short"
        elif ! check_rclone_remote "$drive" 2>/dev/null; then
            printf "${RED}${SYM_CROSS}%s${NC}${DIM}(no cfg)${NC} " "$short"
        else
            printf "${DIM}${SYM_CIRCLE}%s${NC} " "$short"
        fi
    done
    printf "\n"

    # Phone & Containers - one line
    printf "  ${BLUE}Phone:${NC}   "
    if phone_is_reachable 2>/dev/null && phone_is_mounted 2>/dev/null; then
        printf "${GREEN}${SYM_DOT}${NC} mounted"
    elif phone_is_reachable 2>/dev/null; then
        printf "${YELLOW}${SYM_CIRCLE}${NC} reachable"
    else
        printf "${DIM}${SYM_CIRCLE}${NC} offline"
    fi

    count=$(find "$FUSE_DIR/Containers/" -maxdepth 1 -type l 2>/dev/null | wc -l)
    printf "   ${BLUE}Cntrs:${NC} ${GREEN}%s${NC}\n" "$count"
}

show_menu() {
    clear
    printf "${CYAN}${BOLD}"
    printf "╔══════════════════════════════════════════════╗\n"
    printf "║         FUSE Mount Manager v1.1              ║\n"
    printf "╚══════════════════════════════════════════════╝${NC}\n\n"

    # Status bar
    printf "${DIM}─────────────────── Status ───────────────────${NC}\n"
    compact_status
    printf "${DIM}───────────────────────────────────────────────${NC}\n\n"

    # Mount section
    printf "${GREEN}${BOLD}▸ Mount${NC}\n"
    printf "  ${GREEN}1${NC}  Mount all (VMs + Drives)    ${GREEN}5${NC}  Mount single VM\n"
    printf "  ${GREEN}2${NC}  Mount all VMs               ${GREEN}6${NC}  Mount single Drive\n"
    printf "  ${GREEN}3${NC}  Mount all Drives            ${GREEN}p${NC}  Mount Phone\n"
    printf "\n"

    # Unmount section
    printf "${RED}${BOLD}▸ Unmount${NC}\n"
    printf "  ${RED}7${NC}  Unmount all                  ${RED}10${NC} Unmount single VM\n"
    printf "  ${RED}8${NC}  Unmount all VMs              ${RED}11${NC} Unmount single Drive\n"
    printf "  ${RED}9${NC}  Unmount all Drives           ${RED}u${NC}  Unmount Phone\n"
    printf "\n"

    # OCI Flex section
    printf "${MAGENTA}${BOLD}▸ OCI Flex (Wake-on-Demand)${NC}\n"
    printf "  ${MAGENTA}f${NC}  Status    ${MAGENTA}F${NC}  Start    ${MAGENTA}x${NC}  Stop    ${MAGENTA}X${NC}  Reset\n"
    printf "\n"

    # Utils section
    printf "${CYAN}${BOLD}▸ Utils${NC}\n"
    printf "  ${CYAN}s${NC}  Full status    ${CYAN}l${NC}  View log    ${CYAN}c${NC}  Clear log\n"
    printf "  ${CYAN}r${NC}  Configure remote (rclone)              ${CYAN}q${NC}  Quit\n"
    printf "\n"

    printf "${BOLD}Choice:${NC} "
}

select_vm() {
    action=$1
    printf "\n${BOLD}Select VM:${NC}\n"
    printf "  1) OCI_micro_0\n"
    printf "  2) OCI_micro_1\n"
    printf "  3) OCI_Flex_1\n"
    printf "  4) GCP_micro_1\n"
    printf "  0) Cancel\n"
    printf "Choice: "
    read -r choice
    case "$choice" in
        1) $action "OCI_micro_0" "OCI_micro_0" ;;
        2) $action "OCI_micro_1" "OCI_micro_1" ;;
        3) $action "OCI_Flex_1" "OCI_Flex_1" ;;
        4) $action "GCP_micro_1" "GCP_micro_1" ;;
        0) return ;;
        *) error "Invalid choice" ;;
    esac
}

select_drive() {
    action=$1
    printf "\n${BOLD}Select Drive:${NC}\n"
    printf "  1) Gdrive_dnm  ${DIM}(diegonmarcos1@gmail.com)${NC}\n"
    printf "  2) Gdrive_me   ${DIM}(me@diegonmarcos.com)${NC}\n"
    printf "  0) Cancel\n"
    printf "Choice: "
    read -r choice
    case "$choice" in
        1) $action "Gdrive_dnm" "Gdrive_dnm" ;;
        2) $action "Gdrive_me" "Gdrive_me" ;;
        0) return ;;
        *) error "Invalid choice" ;;
    esac
}

configure_remote_menu() {
    printf "\n${BOLD}Configure rclone remote:${NC}\n"
    printf "${DIM}Current remotes: $(rclone listremotes | tr '\n' ' ')${NC}\n\n"

    # Show which are missing
    printf "  ${BLUE}Drives:${NC}\n"
    for drive in Gdrive_dnm Gdrive_me; do
        if check_rclone_remote "$drive"; then
            printf "    ${GREEN}${SYM_CHECK}${NC} %s (configured)\n" "$drive"
        else
            printf "    ${RED}${SYM_CROSS}${NC} %s (missing)\n" "$drive"
        fi
    done

    printf "\n  ${BLUE}VMs (SFTP):${NC}\n"
    for vm in OCI_micro_0 OCI_micro_1 OCI_Flex_1 GCP_micro_1; do
        if check_rclone_remote "$vm"; then
            printf "    ${GREEN}${SYM_CHECK}${NC} %s (configured)\n" "$vm"
        else
            printf "    ${RED}${SYM_CROSS}${NC} %s (missing)\n" "$vm"
        fi
    done

    printf "\n${BOLD}Select remote to configure:${NC}\n"
    printf "  1) Gdrive_dnm ${DIM}(diegonmarcos1@)${NC}    5) OCI_micro_0\n"
    printf "  2) Gdrive_me  ${DIM}(me@diegonmarcos)${NC}   6) OCI_micro_1\n"
    printf "  3) (custom)      7) OCI_Flex_1\n"
    printf "  4) Run rclone    8) GCP_micro_1\n"
    printf "     config TUI    0) Cancel\n"
    printf "Choice: "
    read -r choice

    case "$choice" in
        1) create_rclone_remote "Gdrive_dnm" "drive" ;;
        2) create_rclone_remote "Gdrive_me" "drive" ;;
        3)
            printf "Enter remote name: "
            read -r name
            printf "Type (drive/sftp): "
            read -r rtype
            create_rclone_remote "$name" "$rtype"
            ;;
        4) rclone config ;;
        5) create_rclone_remote "OCI_micro_0" "sftp" ;;
        6) create_rclone_remote "OCI_micro_1" "sftp" ;;
        7) create_rclone_remote "OCI_Flex_1" "sftp" ;;
        8) create_rclone_remote "GCP_micro_1" "sftp" ;;
        0) return ;;
        *) error "Invalid choice" ;;
    esac
}

view_log() {
    printf "\n${CYAN}${BOLD}=== Mount Log (last 30 lines) ===${NC}\n"
    if [ -f "$LOG_FILE" ]; then
        tail -30 "$LOG_FILE" | while IFS= read -r line; do
            case "$line" in
                *ERROR*) printf "${RED}%s${NC}\n" "$line" ;;
                *)       printf "${DIM}%s${NC}\n" "$line" ;;
            esac
        done
    else
        printf "${DIM}(No log file yet)${NC}\n"
    fi
    printf "\n${DIM}Log path: %s${NC}\n" "$LOG_FILE"
}

clear_log() {
    if [ -f "$LOG_FILE" ]; then
        : > "$LOG_FILE"
        log "Log cleared"
        printf "Log cleared.\n"
    fi
}

run_tui() {
    while true; do
        show_menu
        read -r choice
        case "$choice" in
            # Mount
            1) mount_all ;;
            2) mount_all_vms; show_status ;;
            3) mount_all_drives; show_status ;;
            p|P|4) mount_phone ;;
            5) select_vm mount_vm; show_status ;;
            6) select_drive mount_drive; show_status ;;
            # Unmount
            7) unmount_all ;;
            8) unmount_all_vms; show_status ;;
            9) unmount_all_drives; show_status ;;
            u|U) unmount_phone ;;
            10) select_vm unmount_vm; show_status ;;
            11) select_drive unmount_drive; show_status ;;
            # OCI Flex
            f) flex_status ;;
            F) flex_start ;;
            x) flex_stop ;;
            X) flex_reset ;;
            # Utils
            s|S) show_status ;;
            l|L) view_log ;;
            c|C) clear_log ;;
            r|R) configure_remote_menu ;;
            q|Q) printf "${GREEN}Bye!${NC}\n"; exit 0 ;;
            *) error "Invalid choice: $choice" ;;
        esac
        printf "\n${DIM}Press Enter to continue...${NC}"
        read -r _
    done
}

# ==============================================================================
# HELP
# ==============================================================================

show_help() {
    cat << 'EOF'
FUSE Mount Manager v1.1 - Unified mount manager for VMs, Drives, and Phones

USAGE:
    mount.sh [COMMAND] [OPTIONS]

COMMANDS:
    (none)          Launch interactive TUI menu
    mount           Mount all (VMs + Drives)
    mount-vms       Mount all VMs
    mount-drives    Mount all Drives
    mount-phone     Mount phone via KDE Connect
    mount-vm NAME   Mount specific VM (OCI_micro_0, OCI_micro_1, OCI_Flex_1, GCP_micro_1)

    unmount         Unmount everything
    unmount-vms     Unmount all VMs
    unmount-drives  Unmount all Drives
    unmount-phone   Unmount phone
    unmount-vm NAME Unmount specific VM

    flex-start      Start OCI Flex VM (wake-on-demand)
    flex-stop       Stop OCI Flex VM
    flex-reset      Force reset OCI Flex VM
    flex-status     Show OCI Flex VM status

    status, s       Show mount status
    log             View debug log (last 50 lines)
    log-clear       Clear debug log
    help, -h        Show this help

EXAMPLES:
    mount.sh                    # Launch TUI
    mount.sh mount              # Mount all
    mount.sh mount-vm OCI_Flex_1
    mount.sh flex-start         # Wake up OCI Flex
    mount.sh status
    mount.sh log                # View errors/debug info

MOUNT STRUCTURE:
    ~/mnt_mnt/
    ├── .mount.log        # Debug log (hidden)
    ├── OCI_micro_0/      # Oracle VM 1 (Mail)
    │   ├── sys/          # Root filesystem
    │   ├── home/         # Home directories
    │   ├── docker/       # Docker volumes
    │   └── mnt/          # Mount points
    ├── OCI_micro_1/      # Oracle VM 2 (Analytics)
    ├── OCI_Flex_1/       # Oracle Flex (Photos) - wake-on-demand
    ├── GCP_micro_1/      # Google Cloud (Proxy)
    ├── Gdrive_dnm/       # Google Drive (dnm account)
    ├── Gdrive_me/        # Google Drive (me account)
    ├── samsung_gS21/     # Phone (KDE Connect)
    └── Containers/       # Symlinks to all docker volumes

REQUIREMENTS:
    - rclone (configured with remotes: rclone config)
    - fusermount
    - oci CLI (for flex control)
    - kdeconnect-cli, qdbus (for phone)

TROUBLESHOOTING:
    If mount fails, check the log: mount.sh log
    To add missing rclone remote: rclone config
EOF
}

# ==============================================================================
# MAIN
# ==============================================================================

case "${1:-}" in
    "")
        run_tui
        ;;
    mount)
        mount_all
        ;;
    mount-vms)
        mount_all_vms
        show_status
        ;;
    mount-drives)
        mount_all_drives
        show_status
        ;;
    mount-phone)
        mount_phone
        ;;
    mount-vm)
        if [ -z "${2:-}" ]; then
            error "Usage: $0 mount-vm NAME"
            exit 1
        fi
        mount_vm "$2" "$2"
        ;;
    unmount|umount)
        unmount_all
        ;;
    unmount-vms|umount-vms)
        unmount_all_vms
        show_status
        ;;
    unmount-drives|umount-drives)
        unmount_all_drives
        show_status
        ;;
    unmount-phone|umount-phone)
        unmount_phone
        ;;
    unmount-vm|umount-vm)
        if [ -z "${2:-}" ]; then
            error "Usage: $0 unmount-vm NAME"
            exit 1
        fi
        unmount_vm "$2"
        ;;
    status|s)
        show_status
        ;;
    log)
        view_log
        ;;
    log-clear)
        clear_log
        ;;
    flex-start)
        flex_start
        ;;
    flex-stop)
        flex_stop
        ;;
    flex-reset)
        flex_reset
        ;;
    flex-status)
        flex_status
        ;;
    help|-h|--help)
        show_help
        ;;
    *)
        error "Unknown command: $1"
        printf "Run '$0 help' for usage\n"
        exit 1
        ;;
esac
