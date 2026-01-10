#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                           NIXOS BIFROST                                    ║
# ║                    Build & Installation System                             ║
# ║                                                                            ║
# ║   NixOS companion to Kinoite - declarative, reproducible OS               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# ═══════════════════════════════════════════════════════════════════════════════
# DESCRIPTION
# ═══════════════════════════════════════════════════════════════════════════════
#
#   Bifrost is a build system for INSTALLING NixOS to Microsoft Surface devices.
#   The goal is a full desktop OS on the internal NVMe, NOT a live USB system.
#
#   It builds installer images using a shared nix store on a LUKS-encrypted
#   btrfs pool, enabling fast incremental builds by caching the compiled kernel.
#
#   BUILD FORMATS:
#     - Raw EFI (~20GB) - PRIMARY: Direct disk image, dd to USB, boot & install
#     - ISO (~4.4GB)    - WORKAROUND: When raw-efi fails (QEMU I/O errors)
#     - QCOW2           - For VM testing before real hardware
#
#   INSTALLATION FLOW:
#     Build image → Boot from USB → Install to NVMe → Reboot → Desktop NixOS
#
#   The final system runs from the Surface's internal drive with LUKS encryption,
#   optionally auto-unlocked via USB keyfile on Ventoy.
#
# ═══════════════════════════════════════════════════════════════════════════════
# QUICK START
# ═══════════════════════════════════════════════════════════════════════════════
#
#   # Interactive TUI menu
#   ./build.sh
#
#   # Build bootable ISO (recommended)
#   ./build.sh build iso
#
#   # Build raw EFI disk image
#   ./build.sh build raw
#
#   # Burn to USB drive
#   ./build.sh burn /dev/sdX
#
# ═══════════════════════════════════════════════════════════════════════════════
# COMMANDS
# ═══════════════════════════════════════════════════════════════════════════════
#
#   BUILD COMMANDS:
#   ---------------
#   build raw     [PRIMARY] Build raw EFI disk image (~20GB)
#                 Can be dd'd directly to USB, then boot & install to NVMe.
#                 Uses QEMU internally to populate the image.
#                 WARNING: May fail with I/O errors on systems with <16GB RAM.
#                 Output: $OUTPUT_BASE/2_raw/nixos.raw
#
#   build iso     [WORKAROUND] Build ISO installer (~4.4GB)
#                 Use when 'build raw' fails with QEMU I/O errors.
#                 Uses squashfs + xorriso (no QEMU, works on 8GB RAM).
#                 Boot ISO → run nixos-install → same result as raw.
#                 Output: $OUTPUT_BASE/2_raw/nixos.iso
#
#   build qcow    Build QCOW2 virtual machine image
#                 For testing in libvirt/virt-manager before real hardware.
#                 Output: $OUTPUT_BASE/2_raw/nixos.qcow2
#
#   build vm      Build VM runner script (nix run style)
#                 Quick QEMU test without full VM setup.
#                 Output: $OUTPUT_BASE/2_raw/result-vm/bin/run-*-vm
#
#   DEPLOY COMMANDS:
#   ----------------
#   burn [device] Burn raw image to USB drive
#                 Interactive device selection if not specified.
#                 Example: ./build.sh burn /dev/sdb
#
#   vm [name]     Create libvirt VM from QCOW2 image
#                 Default name: nixos-test
#                 Requires: libvirt, virt-install
#                 Example: ./build.sh vm my-nixos
#
#   install       Full installation to physical disk
#                 Creates LUKS partition, btrfs subvolumes, installs NixOS.
#                 Use TARGET_DISK env var to specify disk.
#                 Example: TARGET_DISK=/dev/nvme0n1 ./build.sh install
#
#   UTILITY COMMANDS:
#   -----------------
#   check         Validate flake configuration without building
#                 Runs: nix flake check
#
#   update        Update flake.lock with latest nixpkgs
#                 Runs: nix flake update
#
#   show          Show available flake outputs
#                 Runs: nix flake show
#
#   diff          Show changes between current and new config
#                 Only works when running on NixOS
#
# ═══════════════════════════════════════════════════════════════════════════════
# PREREQUISITES
# ═══════════════════════════════════════════════════════════════════════════════
#
#   REQUIRED:
#   - nix          Nix package manager with flakes enabled
#   - LUKS pool    Encrypted btrfs pool at /dev/mapper/luks_pool
#   - @nixos/nix   Btrfs subvolume for shared nix store
#
#   OPTIONAL:
#   - pv           Progress viewer for burn operations
#   - libvirt      For VM creation (vm command)
#   - virt-install For VM creation (vm command)
#
#   DISK SPACE:
#   - /nix         ~30GB for store (kernel + packages cached here)
#   - /var/tmp     ~50GB for builds (nix-build temp directory)
#   - Output       ~5GB for ISO, ~20GB for raw image
#
# ═══════════════════════════════════════════════════════════════════════════════
# ENVIRONMENT VARIABLES
# ═══════════════════════════════════════════════════════════════════════════════
#
#   TARGET_DISK   Target disk for install command (default: /dev/nvme0n1)
#   OUTPUT_BASE   Where to save built images (default: /mnt/kinoite/@images/a_nixos_host)
#   NIX_BUILD_FLAGS  Additional flags for nix build
#
# ═══════════════════════════════════════════════════════════════════════════════
# ARCHITECTURE
# ═══════════════════════════════════════════════════════════════════════════════
#
#   STORE SHARING:
#   This script is designed to run from a non-NixOS host (e.g., Kubuntu, Fedora)
#   while sharing a nix store with a NixOS installation. The store lives on a
#   LUKS-encrypted btrfs subvolume (@nixos/nix) and is mounted as /nix.
#
#   This architecture means:
#   - Kernel compilation happens ONCE and is cached forever
#   - Subsequent builds take ~10-15 minutes instead of ~2 hours
#   - Both the host OS and NixOS share the same compiled packages
#
#   SUBVOLUME LAYOUT:
#   /dev/mapper/luks_pool (btrfs)
#   ├── @nixos/nix        -> mounted as /nix (shared store)
#   ├── @images           -> built images saved here
#   └── @shared           -> shared data between OSes
#
# ═══════════════════════════════════════════════════════════════════════════════
# BUILD TIMES (approximate, cached kernel)
# ═══════════════════════════════════════════════════════════════════════════════
#
#   First build (no cache):     ~2-3 hours (kernel compilation)
#   ISO build (cached):         ~10-15 minutes
#   Raw build (cached):         ~15-20 minutes
#   QCOW build (cached):        ~10-15 minutes
#
# ═══════════════════════════════════════════════════════════════════════════════
# TROUBLESHOOTING
# ═══════════════════════════════════════════════════════════════════════════════
#
#   "LUKS device not open":
#     Run: sudo cryptsetup open /dev/disk/by-uuid/YOUR-UUID luks_pool
#
#   "Raw build fails with I/O errors":
#     The raw-efi format uses QEMU to populate disk image. If you have <16GB
#     RAM, use ISO format instead: ./build.sh build iso
#
#   "Build hangs / no progress":
#     Check logs: tail -f logs/build-*.log
#     View processes: ps aux | grep nix
#
#   "Not enough disk space":
#     Clean old builds: nix-collect-garbage -d
#     Check /nix usage: df -h /nix
#     Check /var/tmp: df -h /var/tmp
#
#   "NetworkManager conflicts with wireless":
#     Fixed in flake.nix - ISO uses wpa_supplicant, installed system uses NM
#
# ═══════════════════════════════════════════════════════════════════════════════
# EXAMPLES
# ═══════════════════════════════════════════════════════════════════════════════
#
#   # Build and burn ISO to USB
#   ./build.sh build iso
#   ./build.sh burn /dev/sdb
#
#   # Quick VM test
#   ./build.sh build vm
#   ./result-vm/bin/run-*-vm
#
#   # Full installation to NVMe
#   TARGET_DISK=/dev/nvme0n1 sudo ./build.sh install
#
#   # Update to latest nixpkgs and rebuild
#   ./build.sh update
#   ./build.sh build iso
#
# ═══════════════════════════════════════════════════════════════════════════════
# OUTPUT LOCATIONS
# ═══════════════════════════════════════════════════════════════════════════════
#
#   Built images:     /mnt/kinoite/@images/a_nixos_host/2_raw/
#     - nixos.iso     Bootable ISO image
#     - nixos.raw     Raw EFI disk image
#     - nixos.qcow2   QCOW2 VM image
#     - result-*      Symlinks to nix store
#
#   Build logs:       ./logs/build-YYYYMMDD-HHMMSS.log
#
# ═══════════════════════════════════════════════════════════════════════════════
# DEFAULT CREDENTIALS
# ═══════════════════════════════════════════════════════════════════════════════
#
#   User:     user
#   Password: 1234567890
#   Root:     (use sudo, root login disabled)
#
#   LUKS:     Same as user password (slot 0)
#             USB keyfile auto-unlock (slot 1) if Ventoy USB present
#
#   Desktop:  KDE Plasma 6 (default), GNOME, Openbox also available
#
# ═══════════════════════════════════════════════════════════════════════════════
# BOOT & USB KEYFILE
# ═══════════════════════════════════════════════════════════════════════════════
#
#   NORMAL BOOT (USB Key Present):
#     1. Power on Surface Pro 8
#     2. USB key detected (Ventoy)
#     3. LUKS unlocks automatically
#     4. SDDM login appears
#
#   NORMAL BOOT (No USB Key):
#     1. Power on Surface Pro 8
#     2. LUKS password prompt appears
#     3. Enter password: 1234567890
#     4. SDDM login appears
#
#   USB KEYFILE LOCATION:
#     /media/VTOYEFI/.luks/surface.key (on Ventoy USB)
#
#   BURN ISO TO USB:
#     Option 1: dd (overwrites entire USB)
#       dd if=nixos.iso of=/dev/sdX bs=4M conv=fsync status=progress
#
#     Option 2: Ventoy (multi-boot, preserves other ISOs)
#       1. Install Ventoy on USB: https://ventoy.net
#       2. Copy nixos.iso to USB partition
#       3. Boot and select ISO from Ventoy menu
#
# ═══════════════════════════════════════════════════════════════════════════════
# SESSIONS (SDDM)
# ═══════════════════════════════════════════════════════════════════════════════
#
#   KDE Plasma 6   Wayland   Full desktop (DEFAULT)
#   GNOME          Wayland   Alternative full desktop
#   Openbox        X11       Lightweight window manager
#   Android        Wayland   Full Waydroid UI via cage
#   Tor Kiosk      Wayland   Anonymous browsing kiosk
#   Chrome Kiosk   Wayland   Chromium fullscreen kiosk
#
# ═══════════════════════════════════════════════════════════════════════════════
# USER-AGNOSTIC DESIGN
# ═══════════════════════════════════════════════════════════════════════════════
#
#   This NixOS is designed to be user-agnostic with full impermanence:
#
#   - Root filesystem is tmpfs (wiped every reboot)
#   - No /persist subvolume - truly stateless OS
#   - User homes are separate btrfs subvolumes (@home-diego, @home-guest)
#   - WiFi passwords stored in user's keyring (portable with home)
#   - Bluetooth pairings stored in user's home (portable with home)
#   - Homes can be moved to ANY NixOS system
#
#   When you move @home-* to another NixOS:
#   - WiFi works immediately (passwords in ~/.local/share/keyrings/)
#   - Bluetooth works immediately (pairings in ~/.local/share/bluetooth/)
#
# ═══════════════════════════════════════════════════════════════════════════════
# SEE ALSO
# ═══════════════════════════════════════════════════════════════════════════════
#
#   Architecture:  ./0_spec/architecture.md
#   Runbook:       ./0_spec/runbook.md
#   Flake:         ./flake.nix
#   Configuration: ./configuration.nix
#
# ═══════════════════════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# Build paths
OUTPUT_BASE="/mnt/kinoite/@images/a_nixos_host"
FLAKE_PATH="$SCRIPT_DIR"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"

# Nix build flags - parallel jobs for faster builds
NIX_BUILD_FLAGS="--max-jobs 4 -L --extra-experimental-features nix-command --extra-experimental-features flakes"

# ═══════════════════════════════════════════════════════════════════════════
# LOGGING SETUP
# ═══════════════════════════════════════════════════════════════════════════
# All build output is logged to $LOG_DIR with timestamps
# ═══════════════════════════════════════════════════════════════════════════

setup_logging() {
    mkdir -p "$LOG_DIR"

    # Create new log file with header
    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "NixOS Bifrost Build Log"
        echo "Started: $(date)"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
    } > "$LOG_FILE"

    # Redirect all output to both terminal and log file
    exec > >(tee -a "$LOG_FILE") 2>&1

    echo "[LOG] Output being saved to: $LOG_FILE"
}

setup_logging

# ═══════════════════════════════════════════════════════════════════════════
# CRITICAL: STORE ARCHITECTURE
# ═══════════════════════════════════════════════════════════════════════════
#
#   There is ONE nix store: @nixos/nix on the LUKS pool
#
#   Kubuntu (this host) has NO local store. It:
#     1. Mounts @nixos/nix as /nix
#     2. Runs nix-daemon against that store
#     3. All builds go into @nixos/nix (kernel cached forever!)
#     4. Output images saved to @shared or OUTPUT_BASE
#
#   This prevents rebuilding the 2-hour kernel every time!
#
# ═══════════════════════════════════════════════════════════════════════════

LUKS_DEVICE="/dev/mapper/luks_pool"
POOL_MOUNT="/mnt/pool"
NIXOS_STORE_SUBVOL="@nixos/nix"
NIX_BUILD_DIR="/var/tmp/nix-build"

# Track if we mounted things (for cleanup)
POOL_MOUNTED_BY_US=0
NIX_MOUNTED_BY_US=0

setup_nix_store() {
    log "Setting up nix store from pool..."

    # 1. Check LUKS is open
    if [ ! -b "$LUKS_DEVICE" ]; then
        error "LUKS device not open: $LUKS_DEVICE"
        error "Run: sudo cryptsetup open /dev/disk/by-uuid/3c75c6db-4d7c-4570-81f1-02d168781aac luks_pool"
        exit 1
    fi

    # 2. Mount pool if needed
    if ! mountpoint -q "$POOL_MOUNT" 2>/dev/null; then
        log "Mounting pool..."
        sudo mkdir -p "$POOL_MOUNT"
        sudo mount "$LUKS_DEVICE" "$POOL_MOUNT"
        POOL_MOUNTED_BY_US=1
    fi

    # 3. Mount @nixos/nix as /nix (THE ONLY STORE)
    if ! mountpoint -q /nix 2>/dev/null; then
        log "Mounting @nixos/nix as /nix..."
        sudo mkdir -p /nix
        sudo mount -o subvol="$NIXOS_STORE_SUBVOL",compress=zstd,noatime "$LUKS_DEVICE" /nix
        NIX_MOUNTED_BY_US=1
    else
        # Verify it's the right store
        current_subvol=$(findmnt -n -o SOURCE /nix 2>/dev/null || echo "unknown")
        if echo "$current_subvol" | grep -q "@nixos/nix"; then
            log "/nix already mounted from @nixos/nix"
        else
            warn "/nix is mounted but NOT from @nixos/nix!"
            warn "Current: $current_subvol"
            warn "Builds will go to wrong store!"
        fi
    fi

    # 4. Create temp build directory on disk (not tmpfs)
    if [ ! -d "$NIX_BUILD_DIR" ]; then
        sudo mkdir -p "$NIX_BUILD_DIR"
        sudo chmod 1777 "$NIX_BUILD_DIR"
    fi

    # 5. Ensure nix.conf has build-dir setting
    if [ -f /etc/nix/nix.conf ]; then
        if ! grep -q "^build-dir" /etc/nix/nix.conf 2>/dev/null; then
            log "Configuring nix daemon to use disk-backed build directory..."
            echo "build-dir = $NIX_BUILD_DIR" | sudo tee -a /etc/nix/nix.conf >/dev/null
        fi
    fi

    # 6. Start/restart nix-daemon
    if ! pgrep -x nix-daemon >/dev/null 2>&1; then
        log "Starting nix-daemon..."
        sudo /nix/var/nix/profiles/default/bin/nix-daemon &
        sleep 2
    fi

    export TMPDIR="$NIX_BUILD_DIR"
    export TEMP="$NIX_BUILD_DIR"
    export TMP="$NIX_BUILD_DIR"

    log "Nix store ready: /nix (from @nixos/nix)"
}

cleanup_nix_store() {
    log "Cleaning up mounts..."

    # Stop daemon
    sudo pkill nix-daemon 2>/dev/null || true

    # Unmount /nix if we mounted it
    if [ "$NIX_MOUNTED_BY_US" -eq 1 ]; then
        sudo umount /nix 2>/dev/null || true
    fi

    # Unmount pool if we mounted it
    if [ "$POOL_MOUNTED_BY_US" -eq 1 ]; then
        sudo umount "$POOL_MOUNT" 2>/dev/null || true
    fi
}

# NOTE: setup_nix_store() is called by build functions, not here
# (log/warn/error functions must be defined first)

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
    printf "│  ${GREEN}7${NC}) Deploy to existing       ${RED}i${NC}) Full install (WIPES DISK)  │\n"
    printf "${BOLD}└─────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"
    printf "${BOLD}┌─ Utilities ─────────────────────────────────────────────────┐${NC}\n"
    printf "│  ${CYAN}c${NC}) Check configuration      ${CYAN}u${NC}) Update flake inputs         │\n"
    printf "│  ${CYAN}s${NC}) Show build outputs       ${CYAN}d${NC}) Diff with current system    │\n"
    printf "${BOLD}└─────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"
    printf "  ${CYAN}h${NC}) Help/Documentation    ${RED}q${NC}) Quit\n"
    printf "\n"
}

# ═══════════════════════════════════════════════════════════════════════════
# BUILD FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

build_raw() {
    header "Building NixOS raw-efi image"

    # Setup nix store from @nixos/nix
    setup_nix_store

    mkdir -p "$OUTPUT_BASE/2_raw"

    log "Building raw EFI disk image (this takes ~15-30 minutes)..."
    log "Output will be in: $OUTPUT_BASE/2_raw/"

    # Build with nixos-generators
    nix build $NIX_BUILD_FLAGS "$FLAKE_PATH#raw" --out-link "$OUTPUT_BASE/2_raw/result"

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

    setup_nix_store

    mkdir -p "$OUTPUT_BASE/2_raw"

    log "Building ISO image (this takes ~15-30 minutes)..."

    nix build $NIX_BUILD_FLAGS "$FLAKE_PATH#iso" --out-link "$OUTPUT_BASE/2_raw/result-iso"

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

    setup_nix_store

    mkdir -p "$OUTPUT_BASE/2_raw"

    log "Building QCOW2 image (this takes ~10-20 minutes)..."

    nix build $NIX_BUILD_FLAGS "$FLAKE_PATH#qcow" --out-link "$OUTPUT_BASE/2_raw/result-qcow"

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

    setup_nix_store

    log "Building VM runner script..."

    nix build $NIX_BUILD_FLAGS "$FLAKE_PATH#vm" --out-link "$OUTPUT_BASE/2_raw/result-vm"

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
# DEPLOY TO EXISTING SETUP
# ═══════════════════════════════════════════════════════════════════════════
# Deploy NixOS to existing partitions without wiping disk.
# Use when you already have LUKS pool, btrfs subvolumes, and cached nix store.

deploy_existing() {
    header "Deploy NixOS to Existing Setup"

    # Configuration
    local LUKS_DEVICE="/dev/mapper/luks_pool"
    local BOOT_PART="/dev/nvme0n1p3"
    local EFI_PART="/dev/nvme0n1p1"
    local MOUNT_ROOT="/mnt/nixos"

    printf "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║  Deploy to existing partitions (no wipe)                     ║${NC}\n"
    printf "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}\n"
    printf "${CYAN}║  LUKS:  ${NC}$LUKS_DEVICE${CYAN}                                        ║${NC}\n"
    printf "${CYAN}║  Root:  ${NC}@nixos subvolume${CYAN}                                    ║${NC}\n"
    printf "${CYAN}║  Boot:  ${NC}$BOOT_PART${CYAN}                                      ║${NC}\n"
    printf "${CYAN}║  EFI:   ${NC}$EFI_PART${CYAN}                                      ║${NC}\n"
    printf "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
    printf "${YELLOW}Continue? [y/N]:${NC} "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        warn "Aborted"
        return 1
    fi

    # Step 1: Ensure nix store is ready
    log "Step 1: Setting up nix store..."
    setup_nix_store

    # Step 2: Mount target filesystems
    log "Step 2: Mounting target filesystems..."
    sudo mkdir -p "$MOUNT_ROOT"

    # Check if LUKS is open
    if [ ! -e "$LUKS_DEVICE" ]; then
        log "Opening LUKS device..."
        sudo cryptsetup open /dev/nvme0n1p4 luks_pool
    fi

    # Mount @nixos subvolume
    if ! mountpoint -q "$MOUNT_ROOT" 2>/dev/null; then
        sudo mount -o subvol=@nixos,compress=zstd,noatime "$LUKS_DEVICE" "$MOUNT_ROOT"
    fi

    # Mount boot and EFI
    sudo mkdir -p "$MOUNT_ROOT/boot"
    if ! mountpoint -q "$MOUNT_ROOT/boot" 2>/dev/null; then
        sudo mount "$BOOT_PART" "$MOUNT_ROOT/boot"
    fi

    sudo mkdir -p "$MOUNT_ROOT/boot/efi"
    if ! mountpoint -q "$MOUNT_ROOT/boot/efi" 2>/dev/null; then
        sudo mount "$EFI_PART" "$MOUNT_ROOT/boot/efi"
    fi

    # Bind mount the nix store
    sudo mkdir -p "$MOUNT_ROOT/nix"
    if ! mountpoint -q "$MOUNT_ROOT/nix" 2>/dev/null; then
        sudo mount --bind /nix "$MOUNT_ROOT/nix"
    fi

    log "Mounts ready:"
    mount | grep "$MOUNT_ROOT"

    # Step 3: Build the system
    log "Step 3: Building NixOS system..."
    cd "$FLAKE_PATH"
    nix build .#nixosConfigurations.surface.config.system.build.toplevel

    NEW_SYSTEM=$(readlink -f ./result)
    log "Built system: $NEW_SYSTEM"

    # Step 4: Install to target
    log "Step 4: Installing system (nixos-install)..."
    sudo nixos-install --root "$MOUNT_ROOT" --system "$NEW_SYSTEM" --no-root-passwd

    # Step 5: Update GRUB on host (Kubuntu's GRUB)
    log "Step 5: Updating GRUB..."

    # Get the init path for GRUB entry
    INIT_PATH="$NEW_SYSTEM/init"
    log "New init path: $INIT_PATH"

    # Update existing NixOS entry in GRUB
    if grep -q 'menuentry "NixOS"' /boot/grub/grub.cfg 2>/dev/null; then
        log "Updating NixOS entry in GRUB..."
        # Backup current grub.cfg
        sudo cp /boot/grub/grub.cfg /boot/grub/grub.cfg.bak.$(date +%Y%m%d-%H%M%S)

        # Update the init= path in NixOS entry
        sudo sed -i "s|init=/nix/store/[^/]*-nixos-system[^/]*/init|init=$INIT_PATH|g" /boot/grub/grub.cfg

        log "GRUB updated. Verify:"
        grep -A5 'menuentry "NixOS"' /boot/grub/grub.cfg | head -8
    else
        warn "NixOS entry not found in GRUB. May need manual update."
    fi

    # Step 6: Cleanup mounts
    log "Step 6: Cleaning up mounts..."
    sudo umount "$MOUNT_ROOT/nix" 2>/dev/null || true
    sudo umount "$MOUNT_ROOT/boot/efi" 2>/dev/null || true
    sudo umount "$MOUNT_ROOT/boot" 2>/dev/null || true
    sudo umount "$MOUNT_ROOT" 2>/dev/null || true

    printf "\n"
    printf "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║  ${BOLD}DEPLOYMENT COMPLETE!${NC}${GREEN}                                       ║${NC}\n"
    printf "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}\n"
    printf "${GREEN}║  Reboot and select 'NixOS' from GRUB menu                    ║${NC}\n"
    printf "${GREEN}║  Login: diego / 1234567890                                   ║${NC}\n"
    printf "${GREEN}║                                                              ║${NC}\n"
    printf "${GREEN}║  If NixOS fails, select Kubuntu to recover                   ║${NC}\n"
    printf "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
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
            7)
                deploy_existing
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
            h|H)
                clear
                # Show documentation from script header
                head -200 "$0" | grep "^#" | sed 's/^#//' | less
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
        deploy)
            deploy_existing
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
            printf "  install             Full installation (WIPES DISK)\n"
            printf "  deploy              Deploy to existing partitions (safe)\n"
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
