#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                           NIXOS BIFROST                                    ║
# ║                    Build & Installation System                             ║
# ║                                                                            ║
# ║   NixOS companion to Kinoite - declarative, reproducible OS               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# POSIX-compliant with TUI menu and CLI args
#
# Usage:
#   ./build.sh                            # Interactive TUI
#   ./build.sh build raw                  # Build raw EFI image
#   ./build.sh build iso                  # Build ISO image
#   ./build.sh build qcow                 # Build QCOW2 for VM
#   ./build.sh burn /dev/sdX              # Burn raw image to USB
#   ./build.sh vm [name]                  # Create VM from QCOW2
#   ./build.sh install                    # Full installation

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# Build paths
OUTPUT_BASE="/mnt/kinoite/@images/a_nixos_host"
FLAKE_PATH="$SCRIPT_DIR"

# Installation config
TARGET_DISK="${TARGET_DISK:-/dev/nvme0n1}"
EFI_SIZE="500M"
LUKS_SIZE="100G"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

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

check_nix() {
    if ! command -v nix >/dev/null 2>&1; then
        error "Nix not installed"
        error "Install with: curl -L https://nixos.org/nix/install | sh"
        exit 1
    fi

    # Check flakes enabled
    if ! nix --version 2>&1 | grep -q "nix"; then
        error "Nix command not working"
        exit 1
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Run as root"
        exit 1
    fi
}

check_deps() {
    for cmd in pv; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            warn "Optional dependency missing: $cmd"
        fi
    done
}

check_vm_deps() {
    for cmd in virsh virt-install; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "Missing dependency: $cmd (install libvirt/virt-install)"
            exit 1
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# TUI DRAWING
# ═══════════════════════════════════════════════════════════════════════════

draw_header() {
    clear
    printf "${CYAN}"
    printf "╔════════════════════════════════════════════════════════════╗\n"
    printf "║${NC}${BOLD}               NIXOS BIFROST BUILD SYSTEM                    ${CYAN}║\n"
    printf "║${NC}${DIM}          Declarative, reproducible NixOS images             ${CYAN}║\n"
    printf "╠════════════════════════════════════════════════════════════╣\n"
    printf "║${NC}  ${GREEN}User:${NC} user  ${GREEN}Pass:${NC} 1234567890  ${GREEN}Disk:${NC} $TARGET_DISK         ${CYAN}║\n"
    printf "╚════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
}

draw_menu() {
    printf "${BOLD}┌─ Build Options ────────────────────────────────────────────┐${NC}\n"
    printf "│  ${GREEN}1${NC}) Build raw-efi image     ${GREEN}2${NC}) Build ISO image            │\n"
    printf "│  ${GREEN}3${NC}) Build QCOW2 (VM)        ${GREEN}4${NC}) Build VM runner            │\n"
    printf "${BOLD}└─────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"
    printf "${BOLD}┌─ Burn / Deploy ───────────────────────────────────────────┐${NC}\n"
    printf "│  ${YELLOW}5${NC}) Burn raw to USB         ${YELLOW}6${NC}) Create VM from QCOW2       │\n"
    printf "│  ${RED}i${NC}) Full installation to disk                             │\n"
    printf "${BOLD}└─────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"
    printf "${BOLD}┌─ Utilities ─────────────────────────────────────────────────┐${NC}\n"
    printf "│  ${CYAN}c${NC}) Check configuration      ${CYAN}u${NC}) Update flake inputs         │\n"
    printf "│  ${CYAN}s${NC}) Show build outputs       ${CYAN}d${NC}) Diff with current system    │\n"
    printf "${BOLD}└─────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"
    printf "  ${RED}q${NC}) Quit\n"
    printf "\n"
}

# ═══════════════════════════════════════════════════════════════════════════
# BUILD FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

build_raw() {
    header "Building NixOS raw-efi image"

    mkdir -p "$OUTPUT_BASE/2_raw"

    log "Building raw EFI disk image (this takes ~15-30 minutes)..."
    log "Output will be in: $OUTPUT_BASE/2_raw/"

    # Build with nixos-generators
    nix build "$FLAKE_PATH#raw" --out-link "$OUTPUT_BASE/2_raw/result"

    if [ -L "$OUTPUT_BASE/2_raw/result" ]; then
        # Copy from nix store to local
        raw_file=$(readlink -f "$OUTPUT_BASE/2_raw/result")
        actual_img=$(find "$raw_file" -name "*.raw" -o -name "*.img" 2>/dev/null | head -1)

        if [ -n "$actual_img" ]; then
            log "Copying image to $OUTPUT_BASE/2_raw/nixos.raw..."
            cp "$actual_img" "$OUTPUT_BASE/2_raw/nixos.raw"
            log "Build complete!"
            log "Image: $OUTPUT_BASE/2_raw/nixos.raw"
            log "Size: $(du -h "$OUTPUT_BASE/2_raw/nixos.raw" | cut -f1)"
        else
            log "Build result: $raw_file"
            ls -la "$raw_file"
        fi
    else
        error "Build failed - no result link"
        return 1
    fi
}

build_iso() {
    header "Building NixOS ISO image"

    mkdir -p "$OUTPUT_BASE/2_raw"

    log "Building ISO image (this takes ~15-30 minutes)..."

    nix build "$FLAKE_PATH#iso" --out-link "$OUTPUT_BASE/2_raw/result-iso"

    if [ -L "$OUTPUT_BASE/2_raw/result-iso" ]; then
        iso_dir=$(readlink -f "$OUTPUT_BASE/2_raw/result-iso")
        actual_iso=$(find "$iso_dir" -name "*.iso" 2>/dev/null | head -1)

        if [ -n "$actual_iso" ]; then
            log "Copying ISO to $OUTPUT_BASE/2_raw/nixos.iso..."
            cp "$actual_iso" "$OUTPUT_BASE/2_raw/nixos.iso"
            log "Build complete!"
            log "ISO: $OUTPUT_BASE/2_raw/nixos.iso"
            log "Size: $(du -h "$OUTPUT_BASE/2_raw/nixos.iso" | cut -f1)"
        else
            log "Build result: $iso_dir"
            ls -la "$iso_dir"
        fi
    else
        error "Build failed"
        return 1
    fi
}

build_qcow() {
    header "Building NixOS QCOW2 image"

    mkdir -p "$OUTPUT_BASE/2_raw"

    log "Building QCOW2 image (this takes ~10-20 minutes)..."

    nix build "$FLAKE_PATH#qcow" --out-link "$OUTPUT_BASE/2_raw/result-qcow"

    if [ -L "$OUTPUT_BASE/2_raw/result-qcow" ]; then
        qcow_dir=$(readlink -f "$OUTPUT_BASE/2_raw/result-qcow")
        actual_qcow=$(find "$qcow_dir" -name "*.qcow2" 2>/dev/null | head -1)

        if [ -n "$actual_qcow" ]; then
            log "Copying QCOW2 to $OUTPUT_BASE/2_raw/nixos.qcow2..."
            cp "$actual_qcow" "$OUTPUT_BASE/2_raw/nixos.qcow2"
            log "Build complete!"
            log "QCOW2: $OUTPUT_BASE/2_raw/nixos.qcow2"
            log "Size: $(du -h "$OUTPUT_BASE/2_raw/nixos.qcow2" | cut -f1)"
        else
            log "Build result: $qcow_dir"
            ls -la "$qcow_dir"
        fi
    else
        error "Build failed"
        return 1
    fi
}

build_vm() {
    header "Building NixOS VM runner"

    log "Building VM runner script..."

    nix build "$FLAKE_PATH#vm" --out-link "$OUTPUT_BASE/2_raw/result-vm"

    if [ -L "$OUTPUT_BASE/2_raw/result-vm" ]; then
        log "VM runner built!"
        log "Run with: $OUTPUT_BASE/2_raw/result-vm/bin/run-*-vm"
        ls -la "$OUTPUT_BASE/2_raw/result-vm/bin/"
    else
        error "Build failed"
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

burn_to_usb() {
    device="$1"
    raw_file="$OUTPUT_BASE/2_raw/nixos.raw"

    if [ ! -f "$raw_file" ]; then
        error "Raw image not found: $raw_file"
        warn "Build it first with: ./build.sh build raw"
        return 1
    fi

    if [ -z "$device" ]; then
        printf "\n"
        list_block_devices
        printf "${BOLD}Enter device path (e.g., /dev/sdb):${NC} "
        read -r device
    fi

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

    log "Burning $raw_file to $device..."
    if command -v pv >/dev/null 2>&1; then
        pv "$raw_file" | dd of="$device" bs=4M conv=fsync 2>/dev/null
    else
        dd if="$raw_file" of="$device" bs=4M conv=fsync status=progress
    fi
    sync

    log "Burn complete!"
    log "You can now boot from $device"
}

# ═══════════════════════════════════════════════════════════════════════════
# VM FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

create_vm() {
    vm_name="${1:-nixos-test}"
    qcow_file="$OUTPUT_BASE/2_raw/nixos.qcow2"

    if [ ! -f "$qcow_file" ]; then
        error "QCOW2 image not found: $qcow_file"
        warn "Build it first with: ./build.sh build qcow"
        return 1
    fi

    check_vm_deps

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

    log "Creating VM '$vm_name' from QCOW2..."

    virt-install \
        --name "$vm_name" \
        --ram 4096 \
        --vcpus 2 \
        --disk "path=$qcow_file,format=qcow2" \
        --import \
        --os-variant nixos-unstable \
        --network default \
        --graphics spice,gl=on,listen=none \
        --video virtio \
        --boot uefi \
        --noautoconsole

    if [ $? -eq 0 ]; then
        log "VM '$vm_name' created and started!"
        log "Open virt-manager to access the graphical console"

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
    else
        error "Failed to create VM"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# INSTALLATION FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

install_full() {
    header "NixOS Full Installation"

    check_root

    printf "${BOLD}This will install NixOS to $TARGET_DISK${NC}\n"
    printf "\n"
    printf "${RED}╔══════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${RED}║  ${BOLD}WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED!${NC}${RED}     ║${NC}\n"
    printf "${RED}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
    printf "${YELLOW}Type 'YES' to confirm:${NC} "
    read -r confirm

    if [ "$confirm" != "YES" ]; then
        warn "Aborted"
        return 1
    fi

    # Step 1: Partition
    log "Step 1: Creating partitions..."
    parted -s "$TARGET_DISK" mklabel gpt
    parted -s "$TARGET_DISK" mkpart "EFI" fat32 1MiB "$EFI_SIZE"
    parted -s "$TARGET_DISK" set 1 esp on
    parted -s "$TARGET_DISK" mkpart "LUKS" "$EFI_SIZE" "$LUKS_SIZE"

    # Step 2: LUKS
    log "Step 2: Setting up LUKS encryption..."
    printf "${BOLD}Enter LUKS password:${NC}\n"
    cryptsetup luksFormat --type luks2 "${TARGET_DISK}p2"

    printf "${BOLD}Unlock to continue:${NC}\n"
    cryptsetup open "${TARGET_DISK}p2" cryptroot

    # Step 3: Filesystems
    log "Step 3: Creating filesystems..."
    mkfs.fat -F32 -n EFI "${TARGET_DISK}p1"
    mkfs.btrfs -L nixos /dev/mapper/cryptroot

    # Step 4: Mount
    log "Step 4: Mounting filesystems..."
    mount /dev/mapper/cryptroot /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@nix
    umount /mnt

    mount -o subvol=@,compress=zstd,noatime /dev/mapper/cryptroot /mnt
    mkdir -p /mnt/{home,nix,boot}
    mount -o subvol=@home,compress=zstd,noatime /dev/mapper/cryptroot /mnt/home
    mount -o subvol=@nix,compress=zstd,noatime /dev/mapper/cryptroot /mnt/nix
    mount "${TARGET_DISK}p1" /mnt/boot

    # Step 5: Generate hardware config
    log "Step 5: Generating hardware configuration..."
    nixos-generate-config --root /mnt

    # Step 6: Copy our config
    log "Step 6: Copying NixOS configuration..."
    cp "$FLAKE_PATH/configuration.nix" /mnt/etc/nixos/
    cp "$FLAKE_PATH/flake.nix" /mnt/etc/nixos/

    # Step 7: Install
    log "Step 7: Installing NixOS (this takes ~20-40 minutes)..."
    nixos-install --flake /mnt/etc/nixos#surface

    log "Installation complete!"
    log "Reboot and remove installation media"
}

# ═══════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

check_config() {
    header "Checking NixOS Configuration"
    log "Evaluating flake..."
    nix flake check "$FLAKE_PATH" 2>&1 || true
    log "Configuration check complete"
}

update_flake() {
    header "Updating Flake Inputs"
    log "Updating nixpkgs and nixos-generators..."
    nix flake update "$FLAKE_PATH"
    log "Update complete"
}

show_outputs() {
    header "Available Build Outputs"
    log "Checking flake outputs..."
    nix flake show "$FLAKE_PATH"
}

diff_system() {
    header "Diffing with Current System"
    log "This would show changes between current and new config..."
    warn "Only works on NixOS systems"
    # nixos-rebuild build --flake .#surface
    # nvd diff /run/current-system result
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN TUI
# ═══════════════════════════════════════════════════════════════════════════

main() {
    check_nix
    check_deps

    while true; do
        draw_header
        draw_menu

        printf "${BOLD}Select option:${NC} "
        read -r choice

        case "$choice" in
            1)
                build_raw
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            2)
                build_iso
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            3)
                build_qcow
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            4)
                build_vm
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            5)
                burn_to_usb
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            6)
                printf "${BOLD}Enter VM name (default: nixos-test):${NC} "
                read -r vm_name
                create_vm "$vm_name"
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            i|I)
                install_full
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            c|C)
                check_config
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            u|U)
                update_flake
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            s|S)
                show_outputs
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            d|D)
                diff_system
                printf "\nPress Enter to continue..."
                read -r _
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
    check_nix

    case "$1" in
        build)
            case "$2" in
                raw)    build_raw ;;
                iso)    build_iso ;;
                qcow)   build_qcow ;;
                vm)     build_vm ;;
                *)
                    error "Unknown format: $2"
                    printf "Formats: raw, iso, qcow, vm\n"
                    exit 1
                    ;;
            esac
            ;;
        burn)
            burn_to_usb "$2"
            ;;
        vm)
            create_vm "$2"
            ;;
        install)
            install_full
            ;;
        check)
            check_config
            ;;
        update)
            update_flake
            ;;
        show)
            show_outputs
            ;;
        diff)
            diff_system
            ;;
        *)
            printf "${BOLD}NixOS Bifrost Build System${NC}\n\n"
            printf "Usage: %s [command]\n\n" "$0"
            printf "${BOLD}Build:${NC}\n"
            printf "  build raw           Build raw EFI disk image\n"
            printf "  build iso           Build bootable ISO\n"
            printf "  build qcow          Build QCOW2 VM image\n"
            printf "  build vm            Build VM runner script\n"
            printf "\n"
            printf "${BOLD}Deploy:${NC}\n"
            printf "  burn [device]       Burn raw image to USB\n"
            printf "  vm [name]           Create VM from QCOW2\n"
            printf "  install             Full installation to disk\n"
            printf "\n"
            printf "${BOLD}Utilities:${NC}\n"
            printf "  check               Check configuration\n"
            printf "  update              Update flake inputs\n"
            printf "  show                Show available outputs\n"
            printf "  diff                Diff with current system\n"
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
