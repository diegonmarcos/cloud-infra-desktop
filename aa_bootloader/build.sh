#!/bin/sh
# build.sh — Build and deploy GRUB bootloader from NixOS configuration
# POSIX-compliant. Run as root or with sudo.
#
# Usage:
#   sudo ./build.sh [command]
#
# Commands:
#   generate    Generate all files from bootloader.json (src/ -> dist/)
#   deploy      Deploy generated files to system (dist/ -> /boot/, NixOS)
#   switch      Generate + deploy + nixos-rebuild switch
#   plan        Preview what changes would be made
#   validate    Validate bootloader.json and generated files
#   snapshot    Capture current boot state to logs/snapshots/
#   status      Show current GRUB entries and boot config
#   help        Show this help
#
# Can run from:
#   - NixOS (uses nixos-rebuild directly)
#   - Other Linux (uses chroot into mounted NixOS)

set -eu

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNIX_ROOT="$(dirname "$SCRIPT_DIR")"

# NixOS flake location
NIXOS_FLAKE="$UNIX_ROOT/aa_nixos-surface_host/src"

# Boot partition
BOOT_PARTITION="/boot"
BOOT_UUID="0eaf7961-48c5-4b55-8a8f-04cd0b71de07"

# GRUB configuration files (two-file architecture)
# hardware_grub.nix imports grub-extra-entries.nix via: extraEntries = import ../grub-extra-entries.nix;
GRUB_MAIN="$NIXOS_FLAKE/modules/hardware_grub.nix"
GRUB_EXTRA_ENTRIES="$NIXOS_FLAKE/grub-extra-entries.nix"
GRUB_BOOT="$NIXOS_FLAKE/modules/hardware_boot.nix"

# For cross-OS builds
POOL_MOUNT="${POOL_MOUNT:-/run/media/diego/pool}"
CHROOT_SCRIPT="$UNIX_ROOT/rescue-chroot-nixos.sh"

# Colors (POSIX-safe)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
NC='\033[0m'

# Logging (verbose by default)
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/build-$(date +%Y%m%d).log"
VERBOSE="${VERBOSE:-1}"

# ═══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

init_logging() {
    mkdir -p "$LOG_DIR"
    echo "" >> "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] build.sh $*" >> "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
}

finalize_logging() {
    STATUS=$1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Completed with status: $STATUS" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"

    if [ "$STATUS" -eq 0 ]; then
        info "Log file: $LOG_FILE"
    else
        warn "Check log file for details: $LOG_FILE"
    fi
}

_log() {
    LEVEL="$1"
    MSG="$2"
    TIMESTAMP=$(date '+%H:%M:%S')

    # Always write to log file
    echo "[$TIMESTAMP] [$LEVEL] $MSG" >> "$LOG_FILE"
}

log() {
    _log "INFO" "$1"
    printf "${GREEN}[%s]${NC} %s\n" "$(date '+%H:%M:%S')" "$1"
}

warn() {
    _log "WARN" "$1"
    printf "${YELLOW}[%s]${NC} %s\n" "$(date '+%H:%M:%S')" "$1"
}

error() {
    _log "ERROR" "$1"
    printf "${RED}[%s]${NC} %s\n" "$(date '+%H:%M:%S')" "$1" >&2
}

info() {
    _log "INFO" "$1"
    printf "${BLUE}[%s]${NC} %s\n" "$(date '+%H:%M:%S')" "$1"
}

debug() {
    _log "DEBUG" "$1"
    if [ "$VERBOSE" = "1" ]; then
        printf "${GRAY}[%s] [DEBUG]${NC} %s\n" "$(date '+%H:%M:%S')" "$1"
    fi
}

# Run command with logging
run_cmd() {
    CMD="$*"
    debug "Running: $CMD"

    if [ "$VERBOSE" = "1" ]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        return ${PIPESTATUS[0]}
    else
        OUTPUT=$("$@" 2>&1)
        STATUS=$?
        echo "$OUTPUT" >> "$LOG_FILE"
        if [ $STATUS -ne 0 ]; then
            echo "$OUTPUT"
        fi
        return $STATUS
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Must run as root (use sudo)"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/NIXOS ]; then
        echo "nixos"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

find_boot_partition() {
    # Check standard NixOS location
    if mountpoint -q /boot 2>/dev/null; then
        BOOT_PARTITION="/boot"
        return 0
    fi

    # Check mounted by UUID
    MOUNTED=$(findmnt -rn -S "UUID=$BOOT_UUID" -o TARGET 2>/dev/null || true)
    if [ -n "$MOUNTED" ]; then
        BOOT_PARTITION="$MOUNTED"
        return 0
    fi

    # Try to mount
    if [ -b "/dev/disk/by-uuid/$BOOT_UUID" ]; then
        mkdir -p /mnt/boot-temp
        mount "/dev/disk/by-uuid/$BOOT_UUID" /mnt/boot-temp
        BOOT_PARTITION="/mnt/boot-temp"
        return 0
    fi

    error "Could not find boot partition (UUID: $BOOT_UUID)"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# SOURCE HEADER INJECTION
# ═══════════════════════════════════════════════════════════════════════════════

inject_source_header() {
    # Inject source file comments into grub.cfg after NixOS generates it
    GRUB_CFG="$1"

    if [ ! -f "$GRUB_CFG" ]; then
        return 1
    fi

    # Check if header already exists
    if grep -q "SOURCE FILES:" "$GRUB_CFG" 2>/dev/null; then
        return 0
    fi

    # Create header
    HEADER="# ═══════════════════════════════════════════════════════════════════════════════
# DYNAMICALLY GENERATED BY NIXOS - DO NOT EDIT DIRECTLY!
# ═══════════════════════════════════════════════════════════════════════════════
# Generator:    nixos-rebuild switch (via aa_bootloader/build.sh)
# Generated:    $(date '+%Y-%m-%d %H:%M:%S')
#
# SOURCE FILES:
#   ~/git/unix/aa_nixos-surface_host/src/
#       ├── grub-extra-entries.nix       # Multi-OS boot entries
#       └── modules/hardware_grub.nix    # GRUB configuration
#
# To modify boot entries:
#   1. Edit grub-extra-entries.nix (Arch, Kali, Windows, USB)
#   2. Run: cd ~/git/unix/aa_nixos-surface_host/src && nixos-rebuild switch
#
# ═══════════════════════════════════════════════════════════════════════════════

"

    # Backup and inject
    cp "$GRUB_CFG" "${GRUB_CFG}.pre-header"

    # Replace the first comment line with our header
    {
        echo "$HEADER"
        # Skip the original "Automatically generated" line
        tail -n +2 "$GRUB_CFG"
    } > "${GRUB_CFG}.new"

    mv "${GRUB_CFG}.new" "$GRUB_CFG"
    rm -f "${GRUB_CFG}.pre-header"

    log "Injected source documentation into grub.cfg"
}

# ═══════════════════════════════════════════════════════════════════════════════
# GENERATOR - Create all files from bootloader.json
# ═══════════════════════════════════════════════════════════════════════════════

# Config paths
# src/ = source files (bootloader.json)
# dist/ = generated files (all .nix and .cfg)
BOOTLOADER_CONFIG="$SCRIPT_DIR/src/bootloader.json"
NIX_OUT="$SCRIPT_DIR/dist"
GRUB_OUT="$SCRIPT_DIR/dist"

# Check jq dependency
check_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required but not installed"
        error "Install with: apt install jq / nix-shell -p jq"
        exit 1
    fi
}

# Read JSON value
json_get() {
    jq -r "$1" "$BOOTLOADER_CONFIG"
}

# Generate Linux entry
gen_linux_entry() {
    LABEL="$1"; ROOT_UUID="$2"; KERNEL="$3"; INITRD="$4"; OPTIONS="$5"; CLASS="$6"
    cat << EOF

menuentry "$LABEL" --class $CLASS --class gnu-linux --class gnu --class os {
  insmod part_gpt
  insmod ext2
  search --no-floppy --fs-uuid --set=root $ROOT_UUID
  linux $KERNEL root=UUID=$ROOT_UUID $OPTIONS
  initrd $INITRD
}
EOF
}

# Generate chainloader entry
gen_chainloader_entry() {
    LABEL="$1"; UUID="$2"; EFI_PATH="$3"; CLASS="$4"; SEARCH_FILE="${5:-}"
    cat << EOF

menuentry "$LABEL" --class $CLASS --class os {
  insmod part_gpt
  insmod fat
  insmod chain
EOF
    if [ -n "$SEARCH_FILE" ]; then
        echo "  search --no-floppy --set=root --file $SEARCH_FILE"
    else
        echo "  search --no-floppy --fs-uuid --set=root $UUID"
    fi
    echo "  chainloader $EFI_PATH"
    echo "}"
}

# Generate Arch entries
gen_arch_entries() {
    [ "$(json_get '.entries.arch.enabled')" != "true" ] && return
    echo ""
    echo "# ═══════════════════════════════════════════════════════════════════════════"
    echo "# ARCH OS"
    echo "# ═══════════════════════════════════════════════════════════════════════════"

    gen_linux_entry "$(json_get '.entries.arch.label')" \
        "$(json_get '.entries.arch.root_uuid')" \
        "$(json_get '.entries.arch.kernel')" \
        "$(json_get '.entries.arch.initrd')" \
        "$(json_get '.entries.arch.options')" "arch"

    if [ "$(json_get '.entries.arch.recovery.enabled')" = "true" ]; then
        UUID=$(json_get '.entries.arch.root_uuid')
        echo ""
        echo "submenu \"Arch OS Recovery Mode\" --class arch {"
        cat << EOF
  menuentry "Arch (linux-surface fallback)" --class arch {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root $UUID
    linux $(json_get '.entries.arch.recovery.kernel') root=UUID=$UUID $(json_get '.entries.arch.recovery.options')
    initrd $(json_get '.entries.arch.recovery.initrd')
  }
}
EOF
    fi
}

# Generate Kali entries
gen_kali_entries() {
    [ "$(json_get '.entries.kali.enabled')" != "true" ] && return
    echo ""
    echo "# ═══════════════════════════════════════════════════════════════════════════"
    echo "# KALI LINUX"
    echo "# ═══════════════════════════════════════════════════════════════════════════"

    UUID=$(json_get '.entries.kali.root_uuid')
    KERNEL=$(json_get '.entries.kali.kernel')
    INITRD=$(json_get '.entries.kali.initrd')

    gen_linux_entry "$(json_get '.entries.kali.label')" "$UUID" "$KERNEL" "$INITRD" \
        "$(json_get '.entries.kali.options')" "kali"

    if [ "$(json_get '.entries.kali.recovery.enabled')" = "true" ]; then
        echo ""
        echo "submenu \"Kali Linux Recovery Mode\" --class kali {"
        MODES=$(json_get '.entries.kali.recovery.modes | length')
        i=0
        while [ $i -lt "$MODES" ]; do
            MODE_LABEL=$(json_get ".entries.kali.recovery.modes[$i].label")
            MODE_KERNEL=$(json_get ".entries.kali.recovery.modes[$i].kernel // \"$KERNEL\"")
            MODE_INITRD=$(json_get ".entries.kali.recovery.modes[$i].initrd // \"$INITRD\"")
            MODE_OPTIONS=$(json_get ".entries.kali.recovery.modes[$i].options")
            cat << EOF
  menuentry "$MODE_LABEL" --class kali {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root $UUID
    linux $MODE_KERNEL root=UUID=$UUID $MODE_OPTIONS
    initrd $MODE_INITRD
  }
EOF
            i=$((i + 1))
        done
        echo "}"
    fi
}

# Generate Windows entry
gen_windows_entries() {
    [ "$(json_get '.entries.windows.enabled')" != "true" ] && return
    echo ""
    echo "# ═══════════════════════════════════════════════════════════════════════════"
    echo "# WINDOWS BOOT MANAGER"
    echo "# ═══════════════════════════════════════════════════════════════════════════"
    gen_chainloader_entry "$(json_get '.entries.windows.label')" \
        "$(json_get '.entries.windows.efi_uuid')" \
        "$(json_get '.entries.windows.efi_path')" "windows"
}

# Generate USB entries
gen_usb_entries() {
    [ "$(json_get '.entries.usb.enabled')" != "true" ] && return
    echo ""
    echo "# ═══════════════════════════════════════════════════════════════════════════"
    echo "# USB BOOT OPTIONS"
    echo "# ═══════════════════════════════════════════════════════════════════════════"

    ENTRIES=$(json_get '.entries.usb.entries | length')
    i=0
    while [ $i -lt "$ENTRIES" ]; do
        gen_chainloader_entry "$(json_get ".entries.usb.entries[$i].label")" \
            "$(json_get ".entries.usb.entries[$i].efi_uuid // \"\"")" \
            "$(json_get ".entries.usb.entries[$i].efi_path")" "usb" \
            "$(json_get ".entries.usb.entries[$i].search_file // \"\"")"
        i=$((i + 1))
    done
}

# Generate firmware entry
gen_firmware_entries() {
    [ "$(json_get '.entries.firmware.enabled')" != "true" ] && return
    LABEL=$(json_get '.entries.firmware.label')
    cat << EOF

menuentry "$LABEL" --class settings {
  fwsetup
}
EOF
}

# Generate grub-extra-entries.nix
gen_nix_extra_entries() {
    debug "Generating grub-extra-entries.nix..."
    {
        echo "# GRUB Extra Entries - All OSes"
        echo "# GENERATED FROM: aa_bootloader/src/bootloader.json"
        echo "# DO NOT EDIT - Run ./build.sh generate to regenerate"
        echo ""
        echo "''"
        gen_arch_entries
        gen_kali_entries
        gen_windows_entries
        gen_usb_entries
        gen_firmware_entries
        echo "''"
    } > "$NIX_OUT/grub-extra-entries.nix"
    log "Written: dist/grub-extra-entries.nix"
}

# Generate hardware_grub.nix
gen_hardware_grub_nix() {
    debug "Generating hardware_grub.nix..."
    cat > "$NIX_OUT/hardware_grub.nix" << EOF
# GRUB bootloader configuration
# GENERATED FROM: aa_bootloader/src/bootloader.json
# DO NOT EDIT - Run ./build.sh generate to regenerate
{ config, lib, pkgs, ... }:

{
  boot.loader = {
    efi = {
      canTouchEfiVariables = $(json_get '.efi.can_touch_variables');
      efiSysMountPoint = "$(json_get '.efi.sys_mount_point')";
    };
    grub = {
      enable = true;
      device = "nodev";
      efiSupport = true;
      efiInstallAsRemovable = $(json_get '.efi.install_as_removable');
      default = $(json_get '.grub.default');
      extraEntries = import ../grub-extra-entries.nix;
      extraInstallCommands = ''
        \${pkgs.coreutils}/bin/mkdir -p /boot/efi/EFI/nixos
      '';
    };
  };
}
EOF
    log "Written: dist/hardware_grub.nix"
}

# Generate hardware_boot.nix
gen_hardware_boot_nix() {
    debug "Generating hardware_boot.nix..."
    LUKS_UUID=$(json_get '.luks.uuid')
    KEYFILE_PATH=$(json_get '.luks.keyfile.path')
    KEYFILE_SIZE=$(json_get '.luks.keyfile.size')
    KEYFILE_USB_UUID=$(json_get '.luks.keyfile.usb_uuid')
    FALLBACK=$(json_get '.luks.fallback_to_password')

    cat > "$NIX_OUT/hardware_boot.nix" << EOF
# Boot configuration: LUKS, initrd, Surface modules
# GENERATED FROM: aa_bootloader/src/bootloader.json
# DO NOT EDIT - Run ./build.sh generate to regenerate
{ config, lib, pkgs, ... }:

{
  boot = {
    initrd = {
      availableKernelModules = [
        "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" "uas"
        "btrfs" "vfat" "fat" "nls_cp437" "nls_iso8859-1" "nls_utf8"
      ];
      kernelModules = [
        "dm-snapshot" "vfat" "fat" "nls_cp437" "nls_iso8859-1" "nls_utf8"
        "intel_lpss" "intel_lpss_pci" "8250_dw" "pinctrl_tigerlake" "xhci_pci"
        "surface_aggregator" "surface_aggregator_registry" "surface_aggregator_hub"
        "surface_hid_core" "surface_hid" "hid_multitouch" "hid_generic" "i2c_hid" "i2c_hid_acpi"
      ];
      supportedFilesystems = [ "vfat" ];
      includeDefaultModules = true;

      luks.devices."pool" = {
        device = "/dev/disk/by-uuid/$LUKS_UUID";
        preLVM = true;
        allowDiscards = true;
        keyFile = "/usb-key$KEYFILE_PATH";
        keyFileSize = $KEYFILE_SIZE;
        fallbackToPassword = $FALLBACK;

        preOpenCommands = ''
          echo "[SURFACE] Loading keyboard modules..."
          modprobe surface_aggregator 2>/dev/null || true
          modprobe surface_aggregator_registry 2>/dev/null || true
          modprobe surface_aggregator_hub 2>/dev/null || true
          modprobe surface_hid_core 2>/dev/null || true
          modprobe surface_hid 2>/dev/null || true
          modprobe hid_multitouch 2>/dev/null || true
          sleep 2

          echo "[USB-KEY] Searching for USB keyfile..."
          mkdir -p /usb-key
          if [ -b /dev/disk/by-uuid/$KEYFILE_USB_UUID ]; then
            if mount -t vfat -o ro,iocharset=utf8 /dev/disk/by-uuid/$KEYFILE_USB_UUID /usb-key 2>&1; then
              if [ -f /usb-key$KEYFILE_PATH ]; then
                echo "[USB-KEY] Keyfile found!"
              else
                umount /usb-key 2>/dev/null || true
              fi
            fi
          fi
        '';

        postOpenCommands = ''
          umount /usb-key 2>/dev/null || true
        '';
      };
    };
    kernelModules = [ "kvm-intel" ];
    extraModulePackages = [ ];
  };
}
EOF
    log "Written: dist/hardware_boot.nix"
}

# Generate grub.cfg (reference copy)
gen_grub_cfg() {
    debug "Generating grub.cfg..."
    BOOT_UUID=$(json_get '.partitions.boot.uuid')
    {
        cat << EOF
# ═══════════════════════════════════════════════════════════════════════════════
# GRUB BOOTLOADER CONFIGURATION
# GENERATED FROM: aa_bootloader/src/bootloader.json - DO NOT EDIT DIRECTLY!
# ═══════════════════════════════════════════════════════════════════════════════

search --set=drive1 --fs-uuid $BOOT_UUID
set default=$(json_get '.grub.default')
set timeout=$(json_get '.grub.timeout')
set timeout_style=menu

# NixOS entries are generated by nixos-rebuild switch
EOF
        gen_arch_entries
        gen_kali_entries
        gen_windows_entries
        gen_usb_entries
        gen_firmware_entries
    } > "$GRUB_OUT/grub.cfg"
    log "Written: dist/grub.cfg"
}

# ═══════════════════════════════════════════════════════════════════════════════
# GENERATE COMMAND
# ═══════════════════════════════════════════════════════════════════════════════

do_generate() {
    log "Generating bootloader files from bootloader.json..."

    check_jq

    if [ ! -f "$BOOTLOADER_CONFIG" ]; then
        error "Config not found: $BOOTLOADER_CONFIG"
        exit 1
    fi

    mkdir -p "$GRUB_OUT"

    gen_grub_cfg
    gen_nix_extra_entries
    gen_hardware_grub_nix
    gen_hardware_boot_nix

    echo ""
    info "Generated files in dist/ (NixOS flake symlinks here):"
    ls -la "$NIX_OUT"/*.nix "$GRUB_OUT"/*.cfg 2>/dev/null | sed 's/^/  /'
}

do_build() {
    log "Building NixOS system..."
    debug "Detecting OS..."

    OS=$(detect_os)
    debug "Detected OS: $OS"

    if [ "$OS" = "nixos" ]; then
        log "Running on NixOS - using nixos-rebuild"
        cd "$NIXOS_FLAKE"
        nixos-rebuild build --flake .#surface
        log "Build complete. Run 'deploy' or 'switch' to apply."
    else
        log "Running on $OS - using chroot method"
        if [ ! -x "$CHROOT_SCRIPT" ]; then
            error "Chroot script not found: $CHROOT_SCRIPT"
            error "Run from NixOS or ensure rescue-chroot-nixos.sh exists"
            exit 1
        fi
        "$CHROOT_SCRIPT" --build
    fi
}

do_deploy() {
    log "Deploying generated files..."

    DIST="$SCRIPT_DIR/dist"

    # Check generated files exist
    if [ ! -f "$DIST/grub-extra-entries.nix" ]; then
        error "Generated files not found in dist/"
        error "Run './build.sh generate' first"
        exit 1
    fi

    find_boot_partition
    debug "Boot partition: $BOOT_PARTITION"

    # Deploy Nix files to NixOS flake
    log "Deploying Nix files to NixOS flake..."

    # Backup originals
    BACKUP_DIR="$NIXOS_FLAKE/.backup.$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    for f in grub-extra-entries.nix; do
        if [ -f "$NIXOS_FLAKE/$f" ]; then
            cp "$NIXOS_FLAKE/$f" "$BACKUP_DIR/"
            debug "Backed up: $f"
        fi
    done

    for f in hardware_grub.nix hardware_boot.nix; do
        if [ -f "$NIXOS_FLAKE/modules/$f" ]; then
            cp "$NIXOS_FLAKE/modules/$f" "$BACKUP_DIR/"
            debug "Backed up: modules/$f"
        fi
    done

    # Copy generated files
    cp "$DIST/grub-extra-entries.nix" "$NIXOS_FLAKE/"
    log "Deployed: grub-extra-entries.nix"

    cp "$DIST/hardware_grub.nix" "$NIXOS_FLAKE/modules/"
    log "Deployed: modules/hardware_grub.nix"

    cp "$DIST/hardware_boot.nix" "$NIXOS_FLAKE/modules/"
    log "Deployed: modules/hardware_boot.nix"

    log "Backup saved to: $BACKUP_DIR"
    log "Deploy complete. Run 'switch' to apply via nixos-rebuild."
}

do_switch() {
    log "Full switch: generate -> deploy -> nixos-rebuild..."

    OS=$(detect_os)
    debug "Detected OS: $OS"

    # Step 1: Generate from bootloader.json
    log "Step 1/4: Generating from bootloader.json..."
    do_generate

    # Step 2: Deploy to NixOS flake
    log "Step 2/4: Deploying to NixOS flake..."
    do_deploy

    # Step 3: Run nixos-rebuild
    log "Step 3/4: Running nixos-rebuild switch..."

    if [ "$OS" = "nixos" ]; then
        cd "$NIXOS_FLAKE"
        nixos-rebuild switch --flake .#surface
    else
        log "Running on $OS - using chroot method"
        if [ ! -x "$CHROOT_SCRIPT" ]; then
            error "Chroot script not found: $CHROOT_SCRIPT"
            exit 1
        fi
        "$CHROOT_SCRIPT" --build
        warn "Chroot build complete. Boot into NixOS to run 'nixos-rebuild switch'"
    fi

    # Step 4: Post-processing
    log "Step 4/4: Post-processing..."

    find_boot_partition

    # Inject source documentation header into grub.cfg
    if [ -f "$BOOT_PARTITION/grub/grub.cfg" ]; then
        inject_source_header "$BOOT_PARTITION/grub/grub.cfg"

        # Copy final grub.cfg back to dist/ for reference
        cp "$BOOT_PARTITION/grub/grub.cfg" "$SCRIPT_DIR/dist/grub.cfg.deployed"
        debug "Copied deployed grub.cfg to dist/grub.cfg.deployed"
    fi

    log "Switch complete!"
    info "Source:    src/bootloader.json"
    info "Generated: dist/*.nix"
    info "Deployed:  $NIXOS_FLAKE/"
    info "Active:    $BOOT_PARTITION/grub/grub.cfg"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PLAN COMMAND - Preview changes
# ═══════════════════════════════════════════════════════════════════════════════

do_plan() {
    log "GRUB Configuration Plan"
    echo ""

    # Architecture overview
    info "╔═══════════════════════════════════════════════════════════════════════════╗"
    info "║                    GRUB CONFIGURATION ARCHITECTURE                        ║"
    info "╠═══════════════════════════════════════════════════════════════════════════╣"
    info "║  hardware_grub.nix ─────────imports────────> grub-extra-entries.nix       ║"
    info "║       │                                              │                    ║"
    info "║       ├── boot.loader.grub settings                  ├── Arch OS         ║"
    info "║       ├── EFI configuration                          ├── Kali Linux      ║"
    info "║       └── extraEntries = import ../grub-extra-...    ├── Windows         ║"
    info "║                                                      ├── USB Boot        ║"
    info "║  hardware_boot.nix                                   └── UEFI Settings   ║"
    info "║       │                                                                   ║"
    info "║       ├── LUKS unlock configuration                                       ║"
    info "║       ├── USB keyfile support                                             ║"
    info "║       └── Surface keyboard modules                                        ║"
    info "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Check source files
    log "Source files:"
    for f in "$GRUB_MAIN" "$GRUB_EXTRA_ENTRIES" "$GRUB_BOOT"; do
        if [ -f "$f" ]; then
            SIZE=$(wc -l < "$f")
            printf "  ${GREEN}✓${NC} %s (%d lines)\n" "$(basename "$f")" "$SIZE"
        else
            printf "  ${RED}✗${NC} %s (NOT FOUND)\n" "$(basename "$f")"
        fi
    done
    echo ""

    # Show what's in grub-extra-entries.nix
    log "Multi-OS entries in grub-extra-entries.nix:"
    if [ -f "$GRUB_EXTRA_ENTRIES" ]; then
        grep -E '^menuentry|^submenu' "$GRUB_EXTRA_ENTRIES" 2>/dev/null | \
            sed 's/--class [^ ]*//g' | \
            sed 's/ {$//' | \
            sed 's/menuentry "/  ├── /' | \
            sed 's/submenu "/  ├── [submenu] /' | \
            sed "s/\"$//"
    fi
    echo ""

    # Compare with current grub.cfg
    find_boot_partition || true
    GRUB_CFG="$BOOT_PARTITION/grub/grub.cfg"

    if [ -f "$GRUB_CFG" ]; then
        log "Current grub.cfg entries:"
        grep -E '^menuentry|^submenu' "$GRUB_CFG" 2>/dev/null | head -20 | \
            sed 's/--class [^ ]*//g' | \
            sed 's/ {$//' | \
            sed 's/menuentry "/  ├── /' | \
            sed 's/submenu "/  ├── [submenu] /' | \
            sed "s/\"$//"

        # Check for stale sections (like empty Kubuntu)
        echo ""
        log "Checking for stale sections..."
        if grep -q "KUBUNTU OS" "$GRUB_CFG" 2>/dev/null; then
            # Check if there are any actual menuentry lines between KUBUNTU and next section
            KUBUNTU_ENTRIES=$(sed -n '/KUBUNTU OS/,/^# ═/p' "$GRUB_CFG" | grep -c "^menuentry" || echo "0")
            if [ "$KUBUNTU_ENTRIES" = "0" ]; then
                warn "  Found empty KUBUNTU section header (no entries) - will be cleaned on rebuild"
            fi
        fi

        # Show rescue mode status
        echo ""
        log "Rescue mode status:"
        RESCUE_LINE=$(grep -n "rescue" "$GRUB_CFG" | head -1)
        if echo "$RESCUE_LINE" | grep -q "resume="; then
            warn "  Rescue mode has resume params (NOT a clean rescue!)"
        else
            printf "  ${GREEN}✓${NC} Rescue mode has NO resume params (clean fresh boot)\n"
        fi
    else
        warn "Cannot find current grub.cfg at $GRUB_CFG"
    fi

    echo ""
    log "To apply changes:"
    info "  From NixOS:  sudo ./build.sh switch"
    info "  From Kali:   sudo ./build.sh build  (then boot NixOS to switch)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# VALIDATE COMMAND - Check syntax
# ═══════════════════════════════════════════════════════════════════════════════

do_validate() {
    log "Validating GRUB configuration files..."

    ERRORS=0

    # Check grub-extra-entries.nix syntax
    if [ -f "$GRUB_EXTRA_ENTRIES" ]; then
        log "Checking: grub-extra-entries.nix"

        # Must start and end with ''
        FIRST_CONTENT=$(grep -v '^#' "$GRUB_EXTRA_ENTRIES" | grep -v '^$' | head -1)
        LAST_LINE=$(tail -1 "$GRUB_EXTRA_ENTRIES")

        if [ "$FIRST_CONTENT" = "''" ] && [ "$LAST_LINE" = "''" ]; then
            printf "  ${GREEN}✓${NC} Nix string delimiters correct\n"
        else
            printf "  ${RED}✗${NC} Missing or incorrect '' delimiters\n"
            ERRORS=$((ERRORS + 1))
        fi

        # Check for balanced braces in GRUB entries
        OPEN_BRACES=$(grep -c '{' "$GRUB_EXTRA_ENTRIES" || echo "0")
        CLOSE_BRACES=$(grep -c '}' "$GRUB_EXTRA_ENTRIES" || echo "0")
        if [ "$OPEN_BRACES" = "$CLOSE_BRACES" ]; then
            printf "  ${GREEN}✓${NC} Balanced braces (%s open, %s close)\n" "$OPEN_BRACES" "$CLOSE_BRACES"
        else
            printf "  ${RED}✗${NC} Unbalanced braces (%s open, %s close)\n" "$OPEN_BRACES" "$CLOSE_BRACES"
            ERRORS=$((ERRORS + 1))
        fi

        # Check each menuentry has linux and initrd (or chainloader)
        MENUENTRIES=$(grep -c '^menuentry' "$GRUB_EXTRA_ENTRIES" || echo "0")
        printf "  ${BLUE}ℹ${NC}  Found %s menu entries\n" "$MENUENTRIES"

        # Check UUIDs are referenced
        UUIDS=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9A-F]{4}-[0-9A-F]{4}' "$GRUB_EXTRA_ENTRIES" | sort -u | wc -l)
        printf "  ${BLUE}ℹ${NC}  References %s unique UUIDs\n" "$UUIDS"
    else
        printf "  ${RED}✗${NC} File not found: %s\n" "$GRUB_EXTRA_ENTRIES"
        ERRORS=$((ERRORS + 1))
    fi

    # Check hardware_grub.nix imports correctly
    if [ -f "$GRUB_MAIN" ]; then
        log "Checking: hardware_grub.nix"
        if grep -q 'extraEntries = import ../grub-extra-entries.nix' "$GRUB_MAIN"; then
            printf "  ${GREEN}✓${NC} Correctly imports grub-extra-entries.nix\n"
        else
            printf "  ${RED}✗${NC} Missing import of grub-extra-entries.nix\n"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    echo ""
    if [ "$ERRORS" -eq 0 ]; then
        log "Validation passed - all checks OK"
    else
        error "Validation failed with $ERRORS error(s)"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# SNAPSHOT COMMANDS
# ═══════════════════════════════════════════════════════════════════════════════

do_snapshot() {
    log "Capturing boot state snapshot..."

    SNAP_DIR="$SCRIPT_DIR/logs/snapshots"
    mkdir -p "$SNAP_DIR"

    DATE=$(date +%Y%m%d-%H%M%S)

    find_boot_partition

    # Partition table
    log "Capturing partition table..."
    {
        echo "# Partition table snapshot - $DATE"
        echo ""
        sgdisk -p /dev/nvme0n1 2>/dev/null || fdisk -l /dev/nvme0n1
        echo ""
        parted -s /dev/nvme0n1 print 2>/dev/null || true
    } > "$SNAP_DIR/partition-table.txt"

    # Block devices
    log "Capturing block devices..."
    lsblk -f > "$SNAP_DIR/lsblk.txt"

    # UUIDs
    log "Capturing UUIDs..."
    blkid > "$SNAP_DIR/blkid.txt"

    # EFI boot entries
    log "Capturing EFI entries..."
    efibootmgr -v > "$SNAP_DIR/efi-boot-entries.txt" 2>/dev/null || echo "efibootmgr not available" > "$SNAP_DIR/efi-boot-entries.txt"

    # GRUB config
    log "Capturing GRUB config..."
    cp "$BOOT_PARTITION/grub/grub.cfg" "$SNAP_DIR/grub-cfg.txt"

    # ESP tree
    log "Capturing ESP structure..."
    if [ -d "$BOOT_PARTITION/efi" ]; then
        find "$BOOT_PARTITION/efi" -type f > "$SNAP_DIR/esp-files.txt"
        tree "$BOOT_PARTITION/efi" > "$SNAP_DIR/esp-tree.txt" 2>/dev/null || \
            find "$BOOT_PARTITION/efi" -print > "$SNAP_DIR/esp-tree.txt"
    fi

    # LUKS status (if available)
    log "Capturing LUKS status..."
    {
        echo "# LUKS status - $DATE"
        cryptsetup status pool 2>/dev/null || echo "LUKS pool not open"
        echo ""
        cryptsetup luksDump /dev/nvme0n1p4 2>/dev/null || echo "Cannot dump LUKS header (not root or device missing)"
    } > "$SNAP_DIR/luks-pool-status.txt"

    log "Snapshot saved to: $SNAP_DIR/"
    ls -la "$SNAP_DIR/"
}

# ═══════════════════════════════════════════════════════════════════════════════
# STATUS COMMANDS
# ═══════════════════════════════════════════════════════════════════════════════

do_status() {
    log "Boot configuration status"
    echo ""

    OS=$(detect_os)
    info "Current OS: $OS"

    find_boot_partition || true
    info "Boot partition: $BOOT_PARTITION"

    echo ""
    log "GRUB menu entries:"
    if [ -f "$BOOT_PARTITION/grub/grub.cfg" ]; then
        grep -E '^menuentry|^submenu' "$BOOT_PARTITION/grub/grub.cfg" | \
            sed 's/--class [^ ]*//g' | \
            sed 's/ {$//' | \
            sed 's/menuentry "/  ├── /' | \
            sed 's/submenu "/  ├── [submenu] /' | \
            sed 's/"$//'
    else
        warn "GRUB config not found"
    fi

    echo ""
    log "NixOS specialisations:"
    if [ -d /run/current-system/specialisation ]; then
        ls -1 /run/current-system/specialisation/ | sed 's/^/  ├── /'
    elif [ "$OS" != "nixos" ]; then
        info "(Not running NixOS - cannot check specialisations)"
    else
        warn "No specialisations found"
    fi

    echo ""
    log "Boot files:"
    if [ -d "$BOOT_PARTITION/kernels" ]; then
        ls -lh "$BOOT_PARTITION/kernels/" 2>/dev/null | tail -5 | sed 's/^/  /'
    fi

    echo ""
    log "Disk usage:"
    df -h "$BOOT_PARTITION" 2>/dev/null | tail -1 | awk '{print "  Boot: " $3 " used / " $2 " total (" $5 " used)"}'
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELP
# ═══════════════════════════════════════════════════════════════════════════════

do_help() {
    cat << 'EOF'
aa_bootloader/build.sh — Fully declarative GRUB bootloader management

USAGE:
    ./build.sh [command]

COMMANDS:
    generate    Generate all files from bootloader.json (src/ -> dist/)
    deploy      Deploy generated files (dist/ -> NixOS flake)
    switch      Full pipeline: generate + deploy + nixos-rebuild switch
    plan        Preview changes (diff current vs source)
    validate    Validate bootloader.json syntax
    snapshot    Capture current boot state to logs/snapshots/
    status      Show GRUB entries and boot config
    help        Show this help

EXAMPLES:
    # Edit configuration:
    vim src/bootloader.json

    # Generate files from config:
    ./build.sh generate

    # Preview what would change:
    ./build.sh plan

    # Full pipeline (requires root):
    sudo ./build.sh switch

    # Capture snapshot before changes:
    sudo ./build.sh snapshot

ARCHITECTURE (Fully Declarative):

    ┌─────────────────────────────────────────────────────────────────────────┐
    │  SOURCE OF TRUTH: src/bootloader.json                                   │
    │  Contains ALL bootloader configuration in one declarative file          │
    └─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ ./build.sh generate
                                    ▼
    ┌─────────────────────────────────────────────────────────────────────────┐
    │  GENERATED FILES: dist/                                                 │
    │    ├── grub.cfg                  # Full GRUB config (reference)         │
    │    ├── grub-extra-entries.nix    # Multi-OS entries for NixOS           │
    │    ├── hardware_grub.nix         # GRUB loader config                   │
    │    └── hardware_boot.nix         # LUKS, initrd, Surface modules        │
    └─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ ./build.sh deploy
                                    ▼
    ┌─────────────────────────────────────────────────────────────────────────┐
    │  NIXOS FLAKE: aa_nixos-surface_host/src/                                │
    │    ├── grub-extra-entries.nix    # Deployed from dist/                  │
    │    └── modules/                                                         │
    │        ├── hardware_grub.nix     # Deployed from dist/                  │
    │        └── hardware_boot.nix     # Deployed from dist/                  │
    └─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ nixos-rebuild switch
                                    ▼
    ┌─────────────────────────────────────────────────────────────────────────┐
    │  ACTIVE SYSTEM: /boot/grub/grub.cfg                                     │
    │  Final generated config active on system                                │
    └─────────────────────────────────────────────────────────────────────────┘

CONFIGURATION (bootloader.json):
    - grub:       Timeout, default entry, colors, graphics
    - efi:        EFI mount points, variables
    - partitions: Boot, EFI, LUKS UUIDs
    - modules:    Required GRUB modules
    - entries:    All OS entries (NixOS, Arch, Kali, Windows, USB)
    - luks:       Encryption config, USB keyfile
    - hibernate:  Resume device and offset
    - surface_pro_8: Hardware-specific modules

FILES:
    src/bootloader.json    # Single source of truth
    src/generate.sh        # Generator script
    dist/                  # Generated output
    logs/                  # Build logs
    a_spec/                # Reference documentation
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    CMD="${1:-help}"

    # Initialize logging for all commands except help
    if [ "$CMD" != "help" ] && [ "$CMD" != "-h" ] && [ "$CMD" != "--help" ]; then
        init_logging "$@"
        debug "Script directory: $SCRIPT_DIR"
        debug "Unix root: $UNIX_ROOT"
        debug "NixOS flake: $NIXOS_FLAKE"
        debug "Boot partition: $BOOT_PARTITION"
        debug "Verbose mode: $VERBOSE"
    fi

    case "$CMD" in
        generate|gen)
            do_generate
            ;;
        deploy)
            check_root
            do_deploy
            ;;
        switch)
            check_root
            do_switch
            ;;
        plan)
            do_plan
            ;;
        validate)
            do_validate
            ;;
        snapshot)
            check_root
            do_snapshot
            ;;
        status)
            do_status
            ;;
        help|-h|--help)
            do_help
            exit 0
            ;;
        *)
            error "Unknown command: $CMD"
            echo ""
            do_help
            finalize_logging 1
            exit 1
            ;;
    esac

    # Finalize logging for successful commands
    if [ "$CMD" != "help" ] && [ "$CMD" != "-h" ] && [ "$CMD" != "--help" ]; then
        finalize_logging 0
    fi
}

main "$@"
