#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                         KINOITE BIFROST                                    ║
# ║                    Build & Installation System                             ║
# ║                                                                            ║
# ║   QubesOS-style isolation optimized for 8GB RAM                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# POSIX-compliant with TUI menu and CLI args
#
# Usage:
#   ./build.sh                            # Interactive TUI
#   ./build.sh build ext4                 # Build ext4 image
#   ./build.sh build btrfs                # Build btrfs image
#   ./build.sh surface                    # Build Bifrost image
#   ./build.sh profile                    # Build user profile container
#   ./build.sh burn ext4 /dev/sdX         # Burn to USB
#   ./build.sh install                    # Full installation
#   ./build.sh install partition          # Partition only
#   ./build.sh install luks               # LUKS setup only
#   ./build.sh install deploy             # Deploy image only
#   ./build.sh install initramfs          # Configure boot only
#   ./build.sh vm ext4 [name] [usb_id]    # Create VM

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# Build config
BASE_IMAGE="quay.io/fedora/fedora-kinoite:41"
IMAGE_NAME="localhost/kinoite-custom:41"

# Installation config
TARGET_DISK="${TARGET_DISK:-/dev/nvme0n1}"
EFI_SIZE="500M"
LUKS_SIZE="215G"
WINDOWS_SIZE="20G"
LUKS_CIPHER="aes-xts-plain64"
LUKS_KEY_SIZE="512"
LUKS_HASH="sha512"
SWAP_SIZE="16G"
INNER_LUKS_SIZE="55G"
RAW_IMAGE="$SCRIPT_DIR/src_btrfs/image/disk.raw"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Box drawing
H_LINE="═"
V_LINE="║"
TL="╔"
TR="╗"
BL="╚"
BR="╝"

log() { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[x]${NC} %s\n" "$1"; }
header() {
    printf "\n${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"
    printf "${BOLD}%s${NC}\n" "$1"
    printf "${CYAN}═══════════════════════════════════════════════════════════════${NC}\n\n"
}

# ═══════════════════════════════════════════════════════════════════════════
# DEPENDENCY CHECKS
# ═══════════════════════════════════════════════════════════════════════════

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Run as root"
        exit 1
    fi
}

check_deps() {
    for cmd in podman pv; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "Missing dependency: $cmd"
            exit 1
        fi
    done
}

check_install_deps() {
    missing=""
    for cmd in parted cryptsetup mkfs.btrfs mkfs.fat btrfs pv rsync; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        error "Missing dependencies:$missing"
        exit 1
    fi
}

check_vm_deps() {
    for cmd in virsh virt-install; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "Missing dependency: $cmd (install libvirt/virt-install)"
            exit 1
        fi
    done
}

check_disk() {
    if [ ! -b "$TARGET_DISK" ]; then
        error "Target disk not found: $TARGET_DISK"
        exit 1
    fi
    if mount | grep -q "^${TARGET_DISK}"; then
        error "Disk $TARGET_DISK has mounted partitions!"
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# TUI DRAWING
# ═══════════════════════════════════════════════════════════════════════════

draw_box() {
    width="$1"
    printf "${CYAN}${TL}"
    i=0; while [ $i -lt "$width" ]; do printf "${H_LINE}"; i=$((i+1)); done
    printf "${TR}${NC}\n"
}

draw_box_bottom() {
    width="$1"
    printf "${CYAN}${BL}"
    i=0; while [ $i -lt "$width" ]; do printf "${H_LINE}"; i=$((i+1)); done
    printf "${BR}${NC}\n"
}

draw_header() {
    clear
    printf "${CYAN}"
    printf "╔════════════════════════════════════════════════════════════╗\n"
    printf "║${NC}${BOLD}              KINOITE BIFROST BUILD SYSTEM                 ${CYAN}║\n"
    printf "║${NC}${DIM}        QubesOS-style isolation for 8GB RAM                ${CYAN}║\n"
    printf "╠════════════════════════════════════════════════════════════╣\n"
    printf "║${NC}  ${GREEN}User:${NC} user  ${GREEN}Pass:${NC} 1234567890  ${GREEN}Disk:${NC} $TARGET_DISK         ${CYAN}║\n"
    printf "╚════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
}

draw_menu() {
    printf "${BOLD}┌─ Build Options (bake) ─────────────────────────────────────┐${NC}\n"
    printf "│  ${GREEN}1${NC}) Build ext4 image        ${GREEN}2${NC}) Build btrfs image          │\n"
    printf "│  ${GREEN}s${NC}) Build Kinoite Bifrost                                   │\n"
    printf "│  ${DIM}   * SSD: KDE, OpenBox, Waydroid, Chrome OS${NC}                │\n"
    printf "${BOLD}└─────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"
    printf "${BOLD}┌─ Burn ────────────────────────────────────────────────────┐${NC}\n"
    printf "│  ${YELLOW}USB:${NC}    ${YELLOW}3${NC}) ext4 to USB    ${YELLOW}4${NC}) btrfs to USB              │\n"
    printf "│  ${RED}DISK:${NC}   ${RED}i${NC}) Full installation (partition+LUKS+deploy)     │\n"
    printf "${BOLD}└─────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"
    printf "${BOLD}┌─ Virtual Machine ──────────────────────────────────────────┐${NC}\n"
    printf "│  ${BLUE}5${NC}) Create VM (ext4)        ${BLUE}6${NC}) Create VM (btrfs)          │\n"
    printf "${BOLD}└─────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"
    printf "${BOLD}┌─ Tools ──────────────────────────────────────────────────────┐${NC}\n"
    printf "│  ${CYAN}7${NC}) Mount VM home           ${CYAN}8${NC}) Unmount VM home            │\n"
    printf "│  ${CYAN}p${NC}) Build user profile container                           │\n"
    printf "${BOLD}└─────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"
    printf "  ${RED}q${NC}) Quit\n"
    printf "\n"
}

draw_install_menu() {
    clear
    printf "${RED}"
    printf "╔════════════════════════════════════════════════════════════╗\n"
    printf "║${NC}${BOLD}           SURFACE PRO DUAL PROFILE INSTALLATION            ${RED}║\n"
    printf "║${NC}${DIM}              Target: $TARGET_DISK                          ${RED}║\n"
    printf "╚════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
    printf "${BOLD}Installation Phases:${NC}\n"
    printf "\n"
    printf "  ${RED}1${NC}) ${BOLD}PARTITION${NC}  - Create GPT partitions (EFI, LUKS, Windows)\n"
    printf "  ${RED}2${NC}) ${BOLD}LUKS${NC}       - Setup dual-password LUKS + BTRFS subvolumes\n"
    printf "  ${RED}3${NC}) ${BOLD}DEPLOY${NC}     - Copy Kinoite image to @root\n"
    printf "  ${RED}4${NC}) ${BOLD}INITRAMFS${NC}  - Configure boot for dual profile detection\n"
    printf "\n"
    printf "  ${RED}a${NC}) ${BOLD}ALL${NC}        - Run complete installation (1-4)\n"
    printf "\n"
    printf "  ${YELLOW}b${NC}) Back to main menu\n"
    printf "\n"
}

# ═══════════════════════════════════════════════════════════════════════════
# MOUNT/UNMOUNT FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

mount_vm_home() {
    vm_name="$1"
    vm_ip="$2"
    mount_point="$3"

    if [ -z "$mount_point" ]; then
        mount_point="$HOME/mnt_mnt/${vm_name}"
    fi

    if ! command -v sshfs >/dev/null 2>&1; then
        error "sshfs not installed. Install with: apt install sshfs"
        return 1
    fi

    if mountpoint -q "$mount_point" 2>/dev/null; then
        warn "Already mounted, unmounting first..."
        fusermount -u "$mount_point" 2>/dev/null || true
    fi

    if [ ! -d "$mount_point" ]; then
        if mkdir -p "$mount_point" 2>/dev/null; then
            : # Success
        else
            log "Creating $mount_point with sudo..."
            sudo mkdir -p "$mount_point"
            sudo chown "$(id -u):$(id -g)" "$mount_point"
        fi
    fi

    log "Mounting VM home to $mount_point..."
    echo "1234567890" | sshfs -o password_stdin,StrictHostKeyChecking=no,UserKnownHostsFile=/dev/null,uid=$(id -u),gid=$(id -g) "user@${vm_ip}:/var/home/user" "$mount_point"

    if [ $? -eq 0 ] && mountpoint -q "$mount_point" 2>/dev/null; then
        log "Mounted successfully!"
        log "VM home available at: $mount_point"
        log "To unmount: fusermount -u $mount_point"
    else
        error "Failed to mount"
        return 1
    fi
}

unmount_vm_home() {
    mount_point="$1"
    if [ -z "$mount_point" ]; then
        error "No mount point specified"
        return 1
    fi
    if mountpoint -q "$mount_point" 2>/dev/null; then
        fusermount -u "$mount_point"
        log "Unmounted $mount_point"
    else
        warn "$mount_point is not mounted"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# BUILD FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

build_container() {
    log "Creating Containerfile..."
    cat > Containerfile << 'DOCKERFILE'
FROM quay.io/fedora/fedora-kinoite:41

RUN useradd -m -G wheel user && \
    echo "user:1234567890" | chpasswd

RUN sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    systemctl enable sshd

RUN echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel-nopasswd && \
    chmod 440 /etc/sudoers.d/wheel-nopasswd

RUN mkdir -p /var/home/user && \
    chown -R user:user /var/home/user
DOCKERFILE

    log "Building container image..."
    podman build --pull=newer --dns=none --no-cache -t "$IMAGE_NAME" -f Containerfile .
}

build_raw() {
    rootfs="$1"
    if [ "$rootfs" = "ext4" ]; then
        output_dir="src_raw"
    else
        output_dir="src_btrfs"
    fi

    printf "\n"
    log "Building $rootfs image..."
    build_container
    mkdir -p "$output_dir"

    log "Building raw disk image ($rootfs) - this takes ~10 minutes..."
    podman run \
        --rm \
        --privileged \
        --pull=never \
        --security-opt label=disable \
        -v "$(pwd)/$output_dir":/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        quay.io/centos-bootc/bootc-image-builder:latest \
        build \
        --type raw \
        --rootfs "$rootfs" \
        --output /output \
        "$IMAGE_NAME"

    raw_file="$output_dir/image/disk.raw"
    if [ -f "$raw_file" ]; then
        log "Build complete!"
        log "Raw image: $raw_file"
        log "Size: $(du -h "$raw_file" | cut -f1)"
    else
        error "Raw image not found"
        return 1
    fi
}

build_profile() {
    profile_image="localhost/kinoite-profile:41"

    printf "\n"
    log "Building USER PROFILE container (dev tools + apps)..."

    if [ ! -f "Containerfile.profile" ]; then
        log "Containerfile.profile not found, creating default..."
        cat > Containerfile.profile << 'DOCKERFILE'
FROM quay.io/fedora/fedora-kinoite:41

RUN rpm-ostree install \
    git vim tmux htop curl wget jq tree ripgrep fd-find fzf \
    gcc g++ make cmake \
    nodejs npm python3 python3-pip rust cargo \
    podman buildah skopeo \
    openssh-clients rsync zsh \
    && rm -rf /var/cache /var/log/dnf*

RUN flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo && \
    flatpak install -y --noninteractive flathub \
    org.mozilla.firefox org.gnome.Calculator org.gnome.TextEditor com.visualstudio.code || true

RUN useradd -m -G wheel user && \
    echo "user:1234567890" | chpasswd && \
    echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel-nopasswd && \
    chmod 440 /etc/sudoers.d/wheel-nopasswd

RUN sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    systemctl enable sshd

RUN mkdir -p /var/home/user/{.config,.local/bin,Projects} && \
    chown -R user:user /var/home/user
DOCKERFILE
    fi

    log "Building profile container image (this takes ~15 minutes)..."
    podman build --pull=newer --no-cache -t "$profile_image" -f Containerfile.profile .

    if [ $? -eq 0 ]; then
        log "Profile container built successfully!"
        log "Image: $profile_image"
    else
        error "Failed to build profile container"
        return 1
    fi
}

build_surface() {
    output_dir="src_btrfs"
    surface_image="localhost/kinoite-surface:41"

    printf "\n"
    log "Building Surface Pro image (KDE + Openbox + Waydroid + Sessions)..."

    if [ ! -f "Containerfile.surface" ]; then
        error "Containerfile.surface not found"
        return 1
    fi

    log "Building Surface container image (this takes ~20 minutes)..."
    podman build --pull=newer --dns=none --no-cache -t "$surface_image" -f Containerfile.surface .

    mkdir -p "$output_dir"

    log "Building raw disk image (btrfs) - this takes ~15 minutes..."
    podman run \
        --rm \
        --privileged \
        --pull=never \
        --security-opt label=disable \
        -v "$(pwd)/$output_dir":/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        quay.io/centos-bootc/bootc-image-builder:latest \
        build \
        --type raw \
        --rootfs btrfs \
        --output /output \
        "$surface_image"

    raw_file="$output_dir/image/disk.raw"
    if [ -f "$raw_file" ]; then
        log "Surface image build complete!"
        log "Raw image: $raw_file"
        log "Size: $(du -h "$raw_file" | cut -f1)"
    else
        error "Raw image not found"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# BURN FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

list_block_devices() {
    printf "${BOLD}Available block devices:${NC}\n\n"
    printf "${YELLOW}%-12s %-8s %-10s %s${NC}\n" "DEVICE" "SIZE" "TYPE" "MODEL"
    printf "%s\n" "─────────────────────────────────────────────────"

    lsblk -d -o NAME,SIZE,TYPE,MODEL -n | while read -r line; do
        name=$(echo "$line" | awk '{print $1}')
        case "$name" in
            loop*|sr*) continue ;;
        esac
        size=$(echo "$line" | awk '{print $2}')
        type=$(echo "$line" | awk '{print $3}')
        model=$(echo "$line" | cut -d' ' -f4-)
        printf "%-12s %-8s %-10s %s\n" "/dev/$name" "$size" "$type" "$model"
    done
    printf "\n"
}

do_burn() {
    raw_file="$1"
    device="$2"

    printf "\n"
    log "Burning $raw_file to $device..."
    pv "$raw_file" | dd of="$device" bs=4M conv=fsync 2>/dev/null
    sync
    printf "\n"
    log "Burn complete!"
    log "You can now boot from $device"
}

burn_to_usb() {
    rootfs="$1"
    if [ "$rootfs" = "ext4" ]; then
        raw_file="src_raw/image/disk.raw"
    else
        raw_file="src_btrfs/image/disk.raw"
    fi

    if [ ! -f "$raw_file" ]; then
        error "Image not found: $raw_file"
        warn "Build the $rootfs image first"
        printf "\nPress Enter to continue..."
        read -r _
        return 1
    fi

    printf "\n"
    list_block_devices

    printf "${BOLD}Enter device path (e.g., /dev/sdb):${NC} "
    read -r device

    if [ -z "$device" ] || [ ! -b "$device" ]; then
        error "Invalid device: $device"
        return 1
    fi

    if mount | grep -q "^$device"; then
        error "Device $device has mounted partitions!"
        return 1
    fi

    dev_size=$(lsblk -d -o SIZE -n "$device" 2>/dev/null || echo "unknown")
    dev_model=$(lsblk -d -o MODEL -n "$device" 2>/dev/null || echo "unknown")
    img_size=$(du -h "$raw_file" | cut -f1)

    printf "\n"
    printf "${RED}╔══════════════════════════════════════════╗${NC}\n"
    printf "${RED}║  ${BOLD}WARNING: ALL DATA WILL BE DESTROYED!${NC}${RED}     ║${NC}\n"
    printf "${RED}╚══════════════════════════════════════════╝${NC}\n"
    printf "\n"
    printf "  Image:  %s (%s)\n" "$raw_file" "$img_size"
    printf "  Target: %s (%s) %s\n" "$device" "$dev_size" "$dev_model"
    printf "\n"
    printf "${YELLOW}Type 'YES' to confirm:${NC} "
    read -r confirm

    if [ "$confirm" != "YES" ]; then
        warn "Aborted"
        return 1
    fi

    do_burn "$raw_file" "$device"

    printf "\nPress Enter to continue..."
    read -r _
}

# ═══════════════════════════════════════════════════════════════════════════
# INSTALLATION PHASE 1: PARTITIONING
# ═══════════════════════════════════════════════════════════════════════════

install_partition() {
    header "PHASE 1: Partitioning $TARGET_DISK"

    check_disk

    disk_size=$(lsblk -b -d -n -o SIZE "$TARGET_DISK" | awk '{print int($1/1024/1024/1024)}')
    log "Disk size: ${disk_size}GB"

    printf "\n${BOLD}Current partition layout:${NC}\n"
    parted "$TARGET_DISK" print 2>/dev/null || true

    printf "\n"
    printf "${RED}╔══════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${RED}║  ${BOLD}WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED!${NC}${RED}     ║${NC}\n"
    printf "${RED}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
    printf "Planned layout:\n"
    printf "  p1: EFI    - %s\n" "$EFI_SIZE"
    printf "  p2: LUKS   - %s\n" "$LUKS_SIZE"
    printf "  p3: Windows - %s\n" "$WINDOWS_SIZE"
    printf "\n"
    printf "${YELLOW}Type 'YES' to confirm:${NC} "
    read -r confirm

    if [ "$confirm" != "YES" ]; then
        warn "Aborted"
        return 1
    fi

    log "Creating GPT partition table..."
    parted -s "$TARGET_DISK" mklabel gpt

    log "Creating EFI partition ($EFI_SIZE)..."
    parted -s "$TARGET_DISK" mkpart "EFI" fat32 1MiB "$EFI_SIZE"
    parted -s "$TARGET_DISK" set 1 esp on

    log "Creating LUKS partition ($LUKS_SIZE)..."
    parted -s "$TARGET_DISK" mkpart "LUKS" "$EFI_SIZE" "$LUKS_SIZE"

    log "Creating Windows partition ($WINDOWS_SIZE)..."
    parted -s "$TARGET_DISK" mkpart "Windows" "$LUKS_SIZE" "100%"

    log "Formatting EFI partition..."
    mkfs.fat -F32 -n EFI "${TARGET_DISK}p1"

    log "Formatting Windows partition (NTFS placeholder)..."
    mkfs.ntfs -f -L Windows "${TARGET_DISK}p3" 2>/dev/null || warn "NTFS format skipped"

    printf "\n${BOLD}Final partition layout:${NC}\n"
    parted "$TARGET_DISK" print

    log "Partitioning complete!"
}

# ═══════════════════════════════════════════════════════════════════════════
# INSTALLATION PHASE 2: LUKS + BTRFS
# ═══════════════════════════════════════════════════════════════════════════

install_luks() {
    header "PHASE 2: Setting up LUKS + BTRFS"

    LUKS_PART="${TARGET_DISK}p2"
    if [ ! -b "$LUKS_PART" ]; then
        error "LUKS partition not found: $LUKS_PART"
        error "Run partition phase first"
        return 1
    fi

    log "Setting up LUKS encryption on $LUKS_PART"

    log "Creating outer LUKS container..."
    printf "${BOLD}Enter ANON password (slot 0):${NC}\n"
    cryptsetup luksFormat \
        --type luks2 \
        --cipher "$LUKS_CIPHER" \
        --key-size "$LUKS_KEY_SIZE" \
        --hash "$LUKS_HASH" \
        --pbkdf argon2id \
        "$LUKS_PART"

    log "Adding AUTH password (slot 1)..."
    printf "${BOLD}Enter existing password (ANON), then new AUTH password:${NC}\n"
    cryptsetup luksAddKey "$LUKS_PART"

    log "Opening outer LUKS..."
    printf "${BOLD}Enter either password to unlock:${NC}\n"
    cryptsetup open "$LUKS_PART" cryptouter

    log "Creating BTRFS filesystem in outer LUKS..."
    mkfs.btrfs -L pool /dev/mapper/cryptouter

    log "Mounting BTRFS pool..."
    mkdir -p /mnt/pool
    mount /dev/mapper/cryptouter /mnt/pool

    log "Creating BTRFS subvolumes..."
    btrfs subvolume create /mnt/pool/@root
    btrfs subvolume create /mnt/pool/@etc-anon
    btrfs subvolume create /mnt/pool/@var-anon
    btrfs subvolume create /mnt/pool/@tools-anon
    btrfs subvolume create /mnt/pool/@vault-anon
    btrfs subvolume create /mnt/pool/@shared-anon
    btrfs subvolume create /mnt/pool/@shared-common
    btrfs subvolume create /mnt/pool/@snapshots
    log "  Created outer LUKS subvolumes"

    log "Creating swap file (${SWAP_SIZE})..."
    touch /mnt/pool/swapfile
    chattr +C /mnt/pool/swapfile
    dd if=/dev/zero of=/mnt/pool/swapfile bs=1G count=16 status=progress
    chmod 600 /mnt/pool/swapfile
    mkswap /mnt/pool/swapfile

    log "Creating inner LUKS container for AUTH profile..."
    inner_size_mb=$((55 * 1024))
    dd if=/dev/zero of=/mnt/pool/auth.luks bs=1M count="$inner_size_mb" status=progress

    log "Formatting inner LUKS..."
    printf "${BOLD}Enter AUTH password for inner LUKS:${NC}\n"
    cryptsetup luksFormat \
        --type luks2 \
        --cipher "$LUKS_CIPHER" \
        --key-size "$LUKS_KEY_SIZE" \
        --hash "$LUKS_HASH" \
        --pbkdf argon2id \
        /mnt/pool/auth.luks

    log "Creating keyfile for automatic inner LUKS unlock..."
    dd if=/dev/urandom of=/mnt/pool/.auth-keyfile bs=4096 count=1
    chmod 000 /mnt/pool/.auth-keyfile

    log "Adding keyfile to inner LUKS..."
    printf "${BOLD}Enter AUTH password to add keyfile:${NC}\n"
    cryptsetup luksAddKey /mnt/pool/auth.luks /mnt/pool/.auth-keyfile

    log "Opening inner LUKS..."
    cryptsetup open /mnt/pool/auth.luks cryptinner --key-file /mnt/pool/.auth-keyfile

    log "Creating BTRFS filesystem in inner LUKS..."
    mkfs.btrfs -L auth /dev/mapper/cryptinner

    mkdir -p /mnt/auth
    mount /dev/mapper/cryptinner /mnt/auth

    btrfs subvolume create /mnt/auth/@etc-auth
    btrfs subvolume create /mnt/auth/@var-auth
    btrfs subvolume create /mnt/auth/@tools-auth
    btrfs subvolume create /mnt/auth/@vault-auth
    btrfs subvolume create /mnt/auth/@shared-auth
    log "  Created inner LUKS subvolumes (AUTH only)"

    log "Unmounting..."
    umount /mnt/auth
    umount /mnt/pool
    cryptsetup close cryptinner
    cryptsetup close cryptouter

    log "LUKS + BTRFS setup complete!"
}

# ═══════════════════════════════════════════════════════════════════════════
# INSTALLATION PHASE 3: DEPLOY IMAGE
# ═══════════════════════════════════════════════════════════════════════════

install_deploy() {
    header "PHASE 3: Deploying Kinoite Image"

    LUKS_PART="${TARGET_DISK}p2"

    if [ ! -f "$RAW_IMAGE" ]; then
        error "Kinoite image not found: $RAW_IMAGE"
        error "Build it first with: ./build.sh surface"
        return 1
    fi

    log "Opening LUKS..."
    printf "${BOLD}Enter LUKS password:${NC}\n"
    cryptsetup open "$LUKS_PART" cryptouter

    log "Mounting @root..."
    mkdir -p /mnt/pool
    mount -o subvol=@root /dev/mapper/cryptouter /mnt/pool

    log "Extracting Kinoite image to @root..."
    mkdir -p /mnt/raw
    LOOP_DEV=$(losetup -f --show -P "$RAW_IMAGE")

    ROOT_PART=""
    for part in "${LOOP_DEV}p3" "${LOOP_DEV}p2" "${LOOP_DEV}p1"; do
        if [ -b "$part" ]; then
            fs_type=$(blkid -o value -s TYPE "$part" 2>/dev/null || echo "")
            if [ "$fs_type" = "btrfs" ] || [ "$fs_type" = "ext4" ]; then
                ROOT_PART="$part"
                break
            fi
        fi
    done

    if [ -z "$ROOT_PART" ]; then
        error "Could not find root partition in image"
        losetup -d "$LOOP_DEV"
        return 1
    fi

    log "Found root partition: $ROOT_PART"
    mount "$ROOT_PART" /mnt/raw

    log "Copying files (this takes a while)..."
    rsync -aAXv --progress /mnt/raw/ /mnt/pool/

    log "Unmounting image..."
    umount /mnt/raw
    losetup -d "$LOOP_DEV"

    log "Initializing profile-specific /etc and /var..."

    mkdir -p /mnt/etc-anon /mnt/var-anon
    mount -o subvol=@etc-anon /dev/mapper/cryptouter /mnt/etc-anon
    mount -o subvol=@var-anon /dev/mapper/cryptouter /mnt/var-anon

    log "Copying /etc to @etc-anon..."
    rsync -aAXv /mnt/pool/etc/ /mnt/etc-anon/

    log "Copying /var to @var-anon..."
    rsync -aAXv /mnt/pool/var/ /mnt/var-anon/

    echo "surface-anon" > /mnt/etc-anon/hostname

    umount /mnt/etc-anon
    umount /mnt/var-anon

    log "Opening inner LUKS for AUTH profile..."
    cryptsetup open /mnt/pool/auth.luks cryptinner --key-file /mnt/pool/.auth-keyfile 2>/dev/null || \
    cryptsetup open /mnt/pool/auth.luks cryptinner

    mkdir -p /mnt/etc-auth /mnt/var-auth
    mount -o subvol=@etc-auth /dev/mapper/cryptinner /mnt/etc-auth
    mount -o subvol=@var-auth /dev/mapper/cryptinner /mnt/var-auth

    log "Copying /etc to @etc-auth..."
    rsync -aAXv /mnt/pool/etc/ /mnt/etc-auth/

    log "Copying /var to @var-auth..."
    rsync -aAXv /mnt/pool/var/ /mnt/var-auth/

    echo "surface-diego" > /mnt/etc-auth/hostname
    echo "diego ALL=(ALL) NOPASSWD: ALL" > /mnt/etc-auth/sudoers.d/diego
    chmod 440 /mnt/etc-auth/sudoers.d/diego

    umount /mnt/etc-auth
    umount /mnt/var-auth
    cryptsetup close cryptinner

    log "Removing /etc and /var from @root..."
    rm -rf /mnt/pool/etc
    rm -rf /mnt/pool/var
    mkdir /mnt/pool/etc
    mkdir /mnt/pool/var

    log "Installing bootloader..."
    EFI_PART="${TARGET_DISK}p1"
    mkdir -p /mnt/pool/boot/efi
    mount "$EFI_PART" /mnt/pool/boot/efi

    if command -v refind-install >/dev/null 2>&1; then
        refind-install --root /mnt/pool
    else
        warn "rEFInd not found, install manually"
    fi

    umount /mnt/pool/boot/efi
    umount /mnt/pool
    cryptsetup close cryptouter

    log "Deployment complete!"
}

# ═══════════════════════════════════════════════════════════════════════════
# INSTALLATION PHASE 4: INITRAMFS
# ═══════════════════════════════════════════════════════════════════════════

install_initramfs() {
    header "PHASE 4: Configuring Initramfs for Dual Profile Boot"

    LUKS_PART="${TARGET_DISK}p2"

    log "Opening LUKS..."
    printf "${BOLD}Enter LUKS password:${NC}\n"
    cryptsetup open "$LUKS_PART" cryptouter

    mkdir -p /mnt/pool
    mount -o subvol=@root /dev/mapper/cryptouter /mnt/pool

    log "Creating profile detection hook..."

    mkdir -p /mnt/pool/etc/dracut.conf.d
    mkdir -p /mnt/pool/usr/lib/dracut/modules.d/99profile-detect

    cat > /mnt/pool/usr/lib/dracut/modules.d/99profile-detect/module-setup.sh << 'EOF'
#!/bin/sh
check() { return 0; }
depends() { echo "crypt btrfs"; }
install() {
    inst_hook pre-mount 99 "$moddir/profile-detect.sh"
    inst_simple "$moddir/mount-profile.sh" /usr/bin/mount-profile.sh
}
EOF
    chmod +x /mnt/pool/usr/lib/dracut/modules.d/99profile-detect/module-setup.sh

    cat > /mnt/pool/usr/lib/dracut/modules.d/99profile-detect/profile-detect.sh << 'EOF'
#!/bin/sh
KEYSLOT=$(cat /run/cryptsetup/cryptouter/keyslot 2>/dev/null || echo "0")
if [ "$KEYSLOT" = "1" ]; then
    echo "auth" > /run/profile
    [ -f /sysroot/.auth-keyfile ] && cryptsetup open /sysroot/auth.luks cryptinner --key-file /sysroot/.auth-keyfile
else
    echo "anon" > /run/profile
fi
EOF
    chmod +x /mnt/pool/usr/lib/dracut/modules.d/99profile-detect/profile-detect.sh

    cat > /mnt/pool/usr/lib/dracut/modules.d/99profile-detect/mount-profile.sh << 'EOF'
#!/bin/sh
PROFILE=$(cat /run/profile 2>/dev/null || echo "anon")
if [ "$PROFILE" = "auth" ]; then
    mount -o subvol=@etc-auth /dev/mapper/cryptinner /sysroot/etc
    mount -o subvol=@var-auth /dev/mapper/cryptinner /sysroot/var
else
    mount -o subvol=@etc-anon /dev/mapper/cryptouter /sysroot/etc
    mount -o subvol=@var-anon /dev/mapper/cryptouter /sysroot/var
fi
EOF
    chmod +x /mnt/pool/usr/lib/dracut/modules.d/99profile-detect/mount-profile.sh

    LUKS_UUID=$(cryptsetup luksUUID "$LUKS_PART")

    cat > /mnt/pool/etc/dracut.conf.d/surface-profile.conf << EOF
add_dracutmodules+=" crypt btrfs profile-detect "
kernel_cmdline="rd.luks.uuid=$LUKS_UUID root=/dev/mapper/cryptouter rootflags=subvol=@root"
EOF

    log "Creating rEFInd configuration..."
    EFI_PART="${TARGET_DISK}p1"
    mount "$EFI_PART" /mnt/pool/boot/efi
    mkdir -p /mnt/pool/boot/efi/EFI/refind

    cat > /mnt/pool/boot/efi/EFI/refind/refind.conf << EOF
timeout 5
use_nvram false
scanfor manual

menuentry "Kinoite ANON" {
    icon /EFI/refind/icons/os_fedora.png
    volume "EFI"
    loader /vmlinuz
    initrd /initramfs.img
    options "rd.luks.uuid=$LUKS_UUID root=/dev/mapper/cryptouter rootflags=subvol=@root ro quiet splash"
}

menuentry "Kinoite AUTH" {
    icon /EFI/refind/icons/os_fedora.png
    volume "EFI"
    loader /vmlinuz
    initrd /initramfs.img
    options "rd.luks.uuid=$LUKS_UUID root=/dev/mapper/cryptouter rootflags=subvol=@root ro quiet splash"
}

menuentry "Windows" {
    icon /EFI/refind/icons/os_win.png
    loader /EFI/Microsoft/Boot/bootmgfw.efi
}
EOF

    umount /mnt/pool/boot/efi
    umount /mnt/pool
    cryptsetup close cryptouter

    log "Initramfs configuration complete!"
    log ""
    log "Boot menu entries created:"
    log "  - Kinoite ANON (enter ANON password)"
    log "  - Kinoite AUTH (enter AUTH password)"
    log "  - Windows"
}

# ═══════════════════════════════════════════════════════════════════════════
# FULL INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════

install_full() {
    header "Surface Pro Dual Profile - Full Installation"

    printf "${BOLD}This will perform a complete installation:${NC}\n"
    printf "  1. Partition disk\n"
    printf "  2. Setup LUKS encryption\n"
    printf "  3. Deploy Kinoite image\n"
    printf "  4. Configure initramfs\n"
    printf "\n"
    printf "Target disk: ${YELLOW}$TARGET_DISK${NC}\n"
    printf "\n"
    printf "${YELLOW}Continue? (y/N):${NC} "
    read -r answer

    if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
        warn "Aborted"
        return 1
    fi

    install_partition
    install_luks
    install_deploy
    install_initramfs

    header "Installation Complete!"

    log "Your Surface Pro is now configured with:"
    log "  - Dual profile LUKS encryption"
    log "  - BTRFS subvolumes for complete isolation"
    log "  - Fedora Kinoite with KDE + Openbox + Waydroid"
    log ""
    log "Reboot and select 'Kinoite ANON' or 'Kinoite AUTH' from rEFInd."
}

# ═══════════════════════════════════════════════════════════════════════════
# VM FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

list_usb_devices() {
    printf "${BOLD}Available USB devices:${NC}\n\n"
    printf "${YELLOW}%-4s %-10s %s${NC}\n" "NUM" "ID" "DESCRIPTION"
    printf "%s\n" "─────────────────────────────────────────────────"

    lsusb | nl -w2 | while read -r num line; do
        id=$(echo "$line" | grep -oE '[0-9a-f]{4}:[0-9a-f]{4}')
        desc=$(echo "$line" | sed 's/.*: ID [0-9a-f:]\+ //')
        printf "%-4s %-10s %s\n" "$num" "$id" "$desc"
    done
    printf "\n"
}

get_usb_by_number() {
    num="$1"
    lsusb | sed -n "${num}p" | grep -oE '[0-9a-f]{4}:[0-9a-f]{4}'
}

create_vm() {
    rootfs="$1"
    vm_name="$2"
    usb_vendor="$3"
    usb_product="$4"

    if [ "$rootfs" = "ext4" ]; then
        raw_file="$(pwd)/src_raw/image/disk.raw"
    else
        raw_file="$(pwd)/src_btrfs/image/disk.raw"
    fi

    if [ ! -f "$raw_file" ]; then
        error "Image not found: $raw_file"
        return 1
    fi

    if [ -z "$vm_name" ]; then
        vm_name="kinoite-${rootfs}"
    fi

    if virsh dominfo "$vm_name" >/dev/null 2>&1; then
        warn "VM '$vm_name' already exists"
        printf "${YELLOW}Delete and recreate? (y/N):${NC} "
        read -r answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            virsh destroy "$vm_name" 2>/dev/null || true
            virsh undefine "$vm_name" --nvram 2>/dev/null || true
        else
            return 1
        fi
    fi

    log "Creating VM '$vm_name' from $rootfs image..."

    if [ -n "$usb_vendor" ] && [ -n "$usb_product" ]; then
        log "USB WiFi passthrough: ${usb_vendor}:${usb_product}"
        virt-install \
            --name "$vm_name" --ram 4096 --vcpus 2 \
            --disk "path=$raw_file,format=raw" --import \
            --os-variant fedora40 --network none \
            --graphics spice,listen=none --video virtio \
            --hostdev "${usb_vendor}:${usb_product}" \
            --boot uefi --noautoconsole
    else
        virt-install \
            --name "$vm_name" --ram 4096 --vcpus 2 \
            --disk "path=$raw_file,format=raw" --import \
            --os-variant fedora40 --network default \
            --graphics spice,listen=none --video virtio \
            --boot uefi --noautoconsole
    fi

    if [ $? -eq 0 ]; then
        log "VM '$vm_name' created and started!"
        log "Open virt-manager to access the graphical console"

        if [ -z "$usb_vendor" ]; then
            printf "Waiting for IP address"
            for _ in 1 2 3 4 5 6; do
                sleep 5
                printf "."
                vm_ip=$(virsh domifaddr "$vm_name" 2>/dev/null | grep -oE '192\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
                [ -n "$vm_ip" ] && break
            done
            printf "\n"

            if [ -n "$vm_ip" ]; then
                log "VM IP: $vm_ip"
                log "SSH: ssh user@$vm_ip (password: 1234567890)"
            fi
        fi
    else
        error "Failed to create VM"
        return 1
    fi
}

tui_create_vm() {
    rootfs="$1"
    check_vm_deps

    if [ "$rootfs" = "ext4" ]; then
        raw_file="src_raw/image/disk.raw"
    else
        raw_file="src_btrfs/image/disk.raw"
    fi

    if [ ! -f "$raw_file" ]; then
        error "Image not found: $raw_file"
        printf "\nPress Enter to continue..."
        read -r _
        return 1
    fi

    printf "\n"
    printf "${BOLD}Enter VM name (default: kinoite-${rootfs}):${NC} "
    read -r vm_name
    [ -z "$vm_name" ] && vm_name="kinoite-${rootfs}"

    printf "\n${BOLD}Network mode:${NC}\n"
    printf "  ${GREEN}1${NC}) NAT (share host internet)\n"
    printf "  ${YELLOW}2${NC}) USB WiFi passthrough (isolated)\n"
    printf "\n${BOLD}Select (default: 1):${NC} "
    read -r net_mode

    usb_vendor=""
    usb_product=""

    if [ "$net_mode" = "2" ]; then
        printf "\n"
        list_usb_devices
        printf "${BOLD}Enter USB device number for WiFi:${NC} "
        read -r usb_num

        if [ -n "$usb_num" ]; then
            usb_id=$(get_usb_by_number "$usb_num")
            if [ -n "$usb_id" ]; then
                usb_vendor=$(echo "$usb_id" | cut -d: -f1)
                usb_product=$(echo "$usb_id" | cut -d: -f2)
            else
                error "Invalid USB device"
                printf "\nPress Enter to continue..."
                read -r _
                return 1
            fi
        fi
    fi

    create_vm "$rootfs" "$vm_name" "$usb_vendor" "$usb_product"

    printf "\nPress Enter to continue..."
    read -r _
}

tui_mount_vm() {
    printf "\n${BOLD}Running VMs:${NC}\n"
    virsh list --name 2>/dev/null | grep -v '^$' | while read -r name; do
        ip=$(virsh domifaddr "$name" 2>/dev/null | grep -oE '192\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        printf "  - %s (%s)\n" "$name" "${ip:-no IP}"
    done
    printf "\n"

    printf "${BOLD}Enter VM name:${NC} "
    read -r vm_name

    if [ -z "$vm_name" ]; then
        error "No VM name specified"
        printf "\nPress Enter to continue..."
        read -r _
        return 1
    fi

    vm_ip=$(virsh domifaddr "$vm_name" 2>/dev/null | grep -oE '192\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$vm_ip" ]; then
        error "Could not get IP for VM '$vm_name'"
        printf "\nPress Enter to continue..."
        read -r _
        return 1
    fi

    printf "${BOLD}Mount point (default: ~/mnt_mnt/${vm_name}):${NC} "
    read -r mount_point

    mount_vm_home "$vm_name" "$vm_ip" "$mount_point"

    printf "\nPress Enter to continue..."
    read -r _
}

tui_unmount_vm() {
    printf "\n${BOLD}Current SSHFS mounts:${NC}\n"
    mount | grep sshfs | while read -r line; do
        printf "  %s\n" "$line"
    done
    printf "\n"

    printf "${BOLD}Enter mount point to unmount:${NC} "
    read -r mount_point

    if [ -z "$mount_point" ]; then
        error "No mount point specified"
        printf "\nPress Enter to continue..."
        read -r _
        return 1
    fi

    unmount_vm_home "$mount_point"

    printf "\nPress Enter to continue..."
    read -r _
}

# ═══════════════════════════════════════════════════════════════════════════
# TUI INSTALL SUBMENU
# ═══════════════════════════════════════════════════════════════════════════

tui_install() {
    check_install_deps

    while true; do
        draw_install_menu

        printf "${BOLD}Select phase:${NC} "
        read -r choice

        case "$choice" in
            1)
                install_partition
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            2)
                install_luks
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            3)
                install_deploy
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            4)
                install_initramfs
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            a|A)
                install_full
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            b|B)
                return
                ;;
            *)
                warn "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN TUI
# ═══════════════════════════════════════════════════════════════════════════

main() {
    check_root
    check_deps

    while true; do
        draw_header
        draw_menu

        printf "${BOLD}Select option:${NC} "
        read -r choice

        case "$choice" in
            1)
                build_raw "ext4"
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            2)
                build_raw "btrfs"
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            s|S)
                build_surface
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            p|P)
                build_profile
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            3)
                burn_to_usb "ext4"
                ;;
            4)
                burn_to_usb "btrfs"
                ;;
            5)
                tui_create_vm "ext4"
                ;;
            6)
                tui_create_vm "btrfs"
                ;;
            7)
                tui_mount_vm
                ;;
            8)
                tui_unmount_vm
                ;;
            i|I)
                tui_install
                ;;
            q|Q)
                printf "\n"
                log "Goodbye!"
                exit 0
                ;;
            *)
                warn "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# CLI HANDLING
# ═══════════════════════════════════════════════════════════════════════════

if [ $# -gt 0 ]; then
    case "$1" in
        mount|unmount)
            ;;
        *)
            check_root
            check_deps
            ;;
    esac

    case "$1" in
        build)
            if [ "$2" != "ext4" ] && [ "$2" != "btrfs" ]; then
                error "Invalid filesystem: $2 (use ext4 or btrfs)"
                exit 1
            fi
            build_raw "$2"
            ;;
        surface)
            build_surface
            ;;
        profile)
            build_profile
            ;;
        burn)
            if [ "$2" != "ext4" ] && [ "$2" != "btrfs" ]; then
                error "Invalid filesystem: $2"
                exit 1
            fi
            if [ -z "$3" ] || [ ! -b "$3" ]; then
                error "Invalid device: $3"
                exit 1
            fi
            if [ "$2" = "ext4" ]; then
                raw_file="src_raw/image/disk.raw"
            else
                raw_file="src_btrfs/image/disk.raw"
            fi
            if [ ! -f "$raw_file" ]; then
                error "Image not found: $raw_file"
                exit 1
            fi
            do_burn "$raw_file" "$3"
            ;;
        install)
            check_install_deps
            case "$2" in
                partition)  install_partition ;;
                luks)       install_luks ;;
                deploy)     install_deploy ;;
                initramfs)  install_initramfs ;;
                ""|full)    install_full ;;
                *)
                    error "Unknown install phase: $2"
                    printf "Phases: partition, luks, deploy, initramfs, full\n"
                    exit 1
                    ;;
            esac
            ;;
        vm)
            check_vm_deps
            if [ "$2" != "ext4" ] && [ "$2" != "btrfs" ]; then
                error "Invalid filesystem: $2"
                exit 1
            fi
            usb_vendor=""
            usb_product=""
            if [ -n "$4" ]; then
                usb_vendor=$(echo "$4" | cut -d: -f1)
                usb_product=$(echo "$4" | cut -d: -f2)
            fi
            create_vm "$2" "$3" "$usb_vendor" "$usb_product"
            ;;
        mount)
            vm_name="$2"
            mount_point="$3"
            if [ -z "$vm_name" ]; then
                error "Usage: $0 mount <vm_name> [mount_point]"
                exit 1
            fi
            vm_ip=$(sudo virsh domifaddr "$vm_name" 2>/dev/null | grep -oE '192\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            if [ -z "$vm_ip" ]; then
                error "Could not get IP for VM '$vm_name'"
                exit 1
            fi
            mount_vm_home "$vm_name" "$vm_ip" "$mount_point"
            ;;
        unmount)
            if [ -z "$2" ]; then
                error "Usage: $0 unmount <mount_point>"
                exit 1
            fi
            unmount_vm_home "$2"
            ;;
        *)
            printf "${BOLD}Kinoite Bifrost Build System${NC}\n\n"
            printf "Usage: %s [command]\n\n" "$0"
            printf "${BOLD}Build:${NC}\n"
            printf "  build <ext4|btrfs>      Build basic raw image\n"
            printf "  surface                 Build Kinoite Bifrost image\n"
            printf "  profile                 Build user profile container\n"
            printf "\n"
            printf "${BOLD}Burn:${NC}\n"
            printf "  burn <ext4|btrfs> <dev> Burn image to USB\n"
            printf "\n"
            printf "${BOLD}Install:${NC}\n"
            printf "  install                 Full installation\n"
            printf "  install partition       Partition disk only\n"
            printf "  install luks            Setup LUKS only\n"
            printf "  install deploy          Deploy image only\n"
            printf "  install initramfs       Configure boot only\n"
            printf "\n"
            printf "${BOLD}VM:${NC}\n"
            printf "  vm <ext4|btrfs> [name] [usb_id]  Create VM\n"
            printf "\n"
            printf "${BOLD}Tools:${NC}\n"
            printf "  mount <vm_name> [path]  Mount VM home via SSHFS\n"
            printf "  unmount <path>          Unmount VM home\n"
            printf "\n"
            printf "${BOLD}Environment:${NC}\n"
            printf "  TARGET_DISK=/dev/sda %s install\n" "$0"
            printf "\n"
            exit 1
            ;;
    esac
else
    main
fi
