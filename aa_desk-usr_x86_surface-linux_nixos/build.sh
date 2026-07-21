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
#   dry-run       Build + diff without applying (nixos-rebuild dry-activate)
#                 On non-NixOS: runs nix flake check (evaluation only)
#
#   update        Update flake.lock — all inputs, or only the named ones
#                 Usage: update [input...]   (e.g. update nixos-hardware)
#                 Runs: nix flake update [input...] --flake src/
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
#   This script is designed to run from a non-NixOS host (e.g., Debian rescue,
#   Ventoy USB, Fedora) while sharing a nix store with a NixOS installation.
#   The store lives on a LUKS-encrypted btrfs subvolume (@nixos/nix) and is
#   mounted as /nix.
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
#   Flake:         ./src/flake.nix
#   Configuration: ./src/configuration.nix
#
# ═══════════════════════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# GUARDRAILS BYPASS — build.sh is the authorized interface
# ═══════════════════════════════════════════════════════════════════════════
export BUILDSH_GUARDRAIL=1
# NixOS setuid wrappers must precede /run/current-system/sw/bin so that
# bare `sudo` resolves to /run/wrappers/bin/sudo (has setuid) not the
# unwrapped nix-store copy (no setuid, fails with "must be owned by uid 0").
PATH="/run/wrappers/bin:$PATH"

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# Build paths
OUTPUT_BASE="/mnt/kinoite/@images/a_nixos_host"
FLAKE_PATH="$SCRIPT_DIR/src"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="${LOG_FILE:-$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log}"

# CPU limits — keep the desktop responsive on the 8-core/8GB Surface.
# --cores: threads per derivation build, --max-jobs: parallel derivations.
# The old 6×2=12-thread setting OVERSUBSCRIBED the 8 cores by 4 and IO-trashed
# interactive sessions (2026-06-12). 4×1 = 4 threads max, half the machine
# stays interactive; nix-daemon additionally runs idle CPU/IO sched class
# (configuration_nix.nix) so builds always yield under contention.
MAX_CORES=4
MAX_JOBS=1
NIX_BUILD_FLAGS="--max-jobs $MAX_JOBS --cores $MAX_CORES -L --extra-experimental-features nix-command --extra-experimental-features flakes"

# ── Two-phase rebuild: nix eval as Diego (user), activation as root ──────────
# Phase 1 — `nix build` runs as Diego (uid 1000), capped by user-1000.slice.
#   The heavy nix evaluation + store build happens here. No root needed.
# Phase 2 — only profile-set + switch-to-configuration run as root (fast,
#   no nix evaluation → can never eat all RAM).
#
# Service suspend/resume policy is declared in cloud-data-nix-build.json
# (suspend_during_build.services). Services not found/running are skipped silently.
_rebuild_exec() {
    local gitconf="$1"
    local mode="$2"  # switch | boot | test | dry-activate
    local result_link="/tmp/nixos-rebuild-result-$$"
    local nix_build_json="$FLAKE_PATH/modules/cloud-data-nix-build.json"

    # ── Read suspend lists from data file ─────────────────────────────────────
    local -a suspend_units=() suspend_sys_units=()
    if command -v jq >/dev/null 2>&1 && [ -f "$nix_build_json" ]; then
        mapfile -t suspend_units < <(jq -r '.suspend_during_build.services[].unit' "$nix_build_json" 2>/dev/null)
        mapfile -t suspend_sys_units < <(jq -r '.suspend_during_build.system_services[]?.unit' "$nix_build_json" 2>/dev/null)
    fi

    # ── Suspend competing services before Phase 1 ─────────────────────────────
    local -a stopped_units=() stopped_sys_units=()
    if [ ${#suspend_units[@]} -gt 0 ]; then
        log "Suspending ${#suspend_units[@]} competing service(s) for the duration of Phase 1…"
        for unit in "${suspend_units[@]}"; do
            if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
                systemctl --user stop "$unit" 2>/dev/null && stopped_units+=("$unit") \
                    && log "  stopped: $unit"
            fi
        done
    fi
    if [ ${#suspend_sys_units[@]} -gt 0 ]; then
        local _sudo_s="/run/wrappers/bin/sudo"; [ -x "$_sudo_s" ] || _sudo_s="sudo"
        log "Suspending ${#suspend_sys_units[@]} SYSTEM service(s) for the duration of Phase 1…"
        for unit in "${suspend_sys_units[@]}"; do
            if systemctl is-active --quiet "$unit" 2>/dev/null; then
                $_sudo_s systemctl stop "$unit" 2>/dev/null && stopped_sys_units+=("$unit") \
                    && log "  stopped (system): $unit"
            fi
        done
    fi

    # Resume ALL stopped units on exit (success, failure, or interrupt)
    _resume_suspended() {
        if [ ${#stopped_units[@]} -gt 0 ]; then
            log "Resuming suspended service(s)…"
            for unit in "${stopped_units[@]}"; do
                systemctl --user start "$unit" 2>/dev/null && log "  started: $unit"
            done
        fi
        if [ ${#stopped_sys_units[@]} -gt 0 ]; then
            local _sudo_r="/run/wrappers/bin/sudo"; [ -x "$_sudo_r" ] || _sudo_r="sudo"
            log "Resuming suspended SYSTEM service(s)…"
            for unit in "${stopped_sys_units[@]}"; do
                $_sudo_r systemctl start "$unit" 2>/dev/null && log "  started (system): $unit"
            done
        fi
    }
    trap _resume_suspended RETURN INT TERM

    # ── Phase 1: nix build in hard-capped transient scope ────────────────────
    # MemorySwapMax=0 = OOM-kill instead of I/O thrash freeze.
    # ionice -c 3 = idle I/O class at the process level — effective on NVMe 'none'
    #   scheduler (IOWeight/IOSchedulingClass are ExecContext properties, unsupported
    #   on --scope transient units; ionice ioprio_set() works unconditionally).
    # IOWeight=10 = cgroup I/O weight for CFQ/BFQ fallback schedulers.
    # ── REINFORCE the freeze-proof caps onto the RUNNING system before building ──────
    # WHY this must run every build (evidence, 2026-06-27): (1) nixos-rebuild switch
    # reloads unit files but does NOT re-apply resource control to the already-running
    # nix-daemon; (2) nix-daemon idle-restarts, dropping --runtime props; (3) the freeze
    # forensics showed the REAL cause was sustained 65% memory-pressure with NO killer
    # firing (oomd had no pressure limit, earlyoom was swap-gated). So before any build we
    # assert BOTH layers and VERIFY they stuck — and REFUSE to build if we can't, because
    # building unprotected is exactly what froze the box 13×. Data-driven from JSON.
    _spjson="$FLAKE_PATH/modules/cloud-data-system-protection.json"
    _sudo="/run/wrappers/bin/sudo"; [ -x "$_sudo" ] || _sudo="sudo"
    if command -v jq >/dev/null 2>&1 && [ -f "$_spjson" ]; then
        _nd_high=$(jq -r .nix_daemon.MemoryHigh "$_spjson")
        _nd_max=$(jq -r .nix_daemon.MemoryMax "$_spjson")
        _nd_swap=$(jq -r .nix_daemon.MemorySwapMax "$_spjson")
        _oomd_lim=$(jq -r .oomd.pressure_limit "$_spjson")
        _gui_min=$(jq -r .gui_session.MemoryMin "$_spjson")
        _gui_high=$(jq -r .gui_session.MemoryHigh "$_spjson")
        _gui_max=$(jq -r .gui_session.MemoryMax "$_spjson")
        _gui_swap=$(jq -r .gui_session.MemorySwapMax "$_spjson")

        log "Reinforce: nix-daemon MemoryMax=$_nd_max MemorySwapMax=$_nd_swap (no swap → OOM-kills a build, never swap-thrash)…"
        $_sudo systemctl set-property --runtime nix-daemon.service \
            MemoryHigh="$_nd_high" MemoryMax="$_nd_max" MemorySwapMax="$_nd_swap" \
            || warn "set-property nix-daemon failed (sudo/polkit?)"

        log "Reinforce: systemd-oomd PSI-kill ($_oomd_lim) on user.slice + system.slice (kills the worst hog on sustained memory pressure)…"
        $_sudo systemctl set-property --runtime user.slice \
            ManagedOOMMemoryPressure=kill ManagedOOMMemoryPressureLimit="$_oomd_lim" \
            || warn "set-property user.slice oomd limit failed"
        $_sudo systemctl set-property --runtime system.slice \
            ManagedOOMMemoryPressure=kill ManagedOOMMemoryPressureLimit="$_oomd_lim" \
            || warn "set-property system.slice oomd limit failed"
        # MemoryHigh/Max reinforced live too: the declared (relaxed) limits must
        # be active BEFORE Phase 1 — otherwise the stale tight limits OOM-kill
        # the very build that would install the new ones (chicken-and-egg,
        # observed 3× on 2026-07-02, casualties included the claude session).
        $_sudo systemctl set-property --runtime user-1000.slice \
            MemoryMin="$_gui_min" MemoryHigh="$_gui_high" MemoryMax="$_gui_max" \
            MemorySwapMax="$_gui_swap" \
            || warn "set-property user-1000.slice failed"

        # FAIL-SAFE: verify the daemon truly cannot swap. If not, refuse to build —
        # better a failed build than a 14th freeze.
        _live_swap=$(systemctl show nix-daemon.service -p MemorySwapMax --value 2>/dev/null)
        if [ "$_live_swap" != "0" ]; then
            error "nix-daemon MemorySwapMax='$_live_swap' (need 0) — REFUSING to build unprotected."
            error "Make 'systemctl set-property nix-daemon.service MemorySwapMax=0' work, then retry."
            return 1
        fi
        log "Verified: nix-daemon swap=0 + oomd PSI-kill live → this build cannot freeze the desktop."
    else
        warn "jq or $_spjson missing — cannot reinforce caps; REFUSING to build unprotected."
        return 1
    fi

    # Scope caps are data-driven from cloud-data-nix-build.json phase1_scope
    # (was hardcoded here and had drifted from the JSON — engine bug fixed 2026-07-02).
    local _p1_props=()
    local _p1_key
    # OOMScoreAdjust: the build scope shares user-1000.slice with the whole
    # desktop (systemd-run --user cannot escape it). On a slice-level MemoryMax
    # OOM the kernel must pick the eval (restartable), never claude/konsole —
    # 2026-07-02 19:30 a slice OOM SIGKILLed claude instead of the build.
    # systemd-run --scope rejects OOMScoreAdjust (exec property, scopes don't
    # fork) → translate the JSON key to a `choom -n` wrapper instead.
    local _p1_choom=()
    local _p1_oomadj
    _p1_oomadj=$(jq -r '.phase1_scope.OOMScoreAdjust // empty' "$nix_build_json")
    [ -n "$_p1_oomadj" ] && _p1_choom=(choom -n "$_p1_oomadj" --)
    for _p1_key in MemoryMax MemoryHigh MemorySwapMax CPUQuota CPUWeight IOWeight; do
        local _p1_val
        _p1_val=$(jq -r ".phase1_scope.${_p1_key} // empty" "$nix_build_json")
        [ -n "$_p1_val" ] && _p1_props+=("--property=${_p1_key}=${_p1_val}")
    done
    log "Phase 1: nix build as $(id -un) — hard-capped scope (${_p1_props[*]#--property=})…"
    GIT_CONFIG_GLOBAL="$gitconf" GIT_CONFIG_SYSTEM="$gitconf" BUILDSH_GUARDRAIL=1 \
        systemd-run --user --scope \
            --unit="nix-build-$$" \
            "${_p1_props[@]}" \
            -- \
            "${_p1_choom[@]}" \
            ionice -c 3 \
            nix build \
                "$FLAKE_PATH#nixosConfigurations.surface.config.system.build.toplevel" \
                --out-link "$result_link" \
                --max-jobs "$MAX_JOBS" --cores "$MAX_CORES" -L \
                --extra-experimental-features "nix-command flakes" || return 1

    # ── Phase 2: activate as root (fast — no nix eval) ───────────────────────
    log "Phase 2: activate as root (fast — no nix eval)…"
    sudo nix-env -p /nix/var/nix/profiles/system --set "$result_link"
    sudo "$result_link/bin/switch-to-configuration" "$mode"
    local rc=$?
    rm -f "$result_link"
    return $rc
}

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

    # Redirect all output to both terminal and log file, timestamping every
    # line ([HH:MM:SS]). 2026-07-21: raw `docker pull` / activation lines had
    # no time frame at all — impossible to tell a live transfer from a stall.
    # gawk strftime + fflush() keeps it line-buffered so the konsole tail sees
    # each line the instant it is written.
    exec > >(stdbuf -oL awk '{ printf "[%s] %s\n", strftime("%H:%M:%S"), $0; fflush() }' | tee -a "$LOG_FILE") 2>&1

    echo "[LOG] Output being saved to: $LOG_FILE"
}

setup_logging

# ═══════════════════════════════════════════════════════════════════════════
# CRITICAL: STORE ARCHITECTURE
# ═══════════════════════════════════════════════════════════════════════════
#
#   There is ONE nix store: @nixos/nix on the LUKS pool
#
#   A non-NixOS host (e.g. rescue-os-debian) has NO local store. It:
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

# ── Perf logging: elapsed time per step ──────────────────────────────────
_PERF_START=$(date +%s%N 2>/dev/null || date +%s)
_PERF_LAST=$_PERF_START

_elapsed_ms() {
    local now
    now=$(date +%s%N 2>/dev/null || date +%s)
    if [ ${#now} -gt 10 ]; then
        # nanosecond precision
        echo $(( (now - _PERF_START) / 1000000 ))
    else
        echo $(( (now - _PERF_START) * 1000 ))
    fi
}

_delta_ms() {
    local now
    now=$(date +%s%N 2>/dev/null || date +%s)
    local delta
    if [ ${#now} -gt 10 ]; then
        delta=$(( (now - _PERF_LAST) / 1000000 ))
    else
        delta=$(( (now - _PERF_LAST) * 1000 ))
    fi
    _PERF_LAST=$now
    echo "$delta"
}

_fmt_ms() {
    local ms=$1
    if [ "$ms" -ge 60000 ]; then
        printf "%dm%ds" $((ms / 60000)) $(( (ms % 60000) / 1000 ))
    elif [ "$ms" -ge 1000 ]; then
        printf "%d.%ds" $((ms / 1000)) $(( (ms % 1000) / 100 ))
    else
        printf "%dms" "$ms"
    fi
}

log() {
    local elapsed delta
    elapsed=$(_elapsed_ms)
    delta=$(_delta_ms)
    printf "${DIM}[%s +%s]${NC} ${GREEN}[+]${NC} %s\n" "$(_fmt_ms "$elapsed")" "$(_fmt_ms "$delta")" "$1"
}
warn() {
    local elapsed delta
    elapsed=$(_elapsed_ms)
    delta=$(_delta_ms)
    printf "${DIM}[%s +%s]${NC} ${YELLOW}[!]${NC} %s\n" "$(_fmt_ms "$elapsed")" "$(_fmt_ms "$delta")" "$1"
}
error() {
    local elapsed delta
    elapsed=$(_elapsed_ms)
    delta=$(_delta_ms)
    printf "${DIM}[%s +%s]${NC} ${RED}[x]${NC} %s\n" "$(_fmt_ms "$elapsed")" "$(_fmt_ms "$delta")" "$1"
}
header() {
    local elapsed delta
    elapsed=$(_elapsed_ms)
    delta=$(_delta_ms)
    printf "\n${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"
    printf "${BOLD}%s${NC} ${DIM}[%s +%s]${NC}\n" "$1" "$(_fmt_ms "$elapsed")" "$(_fmt_ms "$delta")"
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
    printf "${BOLD}┌─ Live System (NixOS only) ────────────────────────────────┐${NC}\n"
    printf "│  ${GREEN}s${NC}) switch  (rebuild & switch)   ${GREEN}b${NC}) boot  (next boot)       │\n"
    printf "│  ${YELLOW}t${NC}) test    (reverts on reboot)                                │\n"
    printf "${BOLD}└─────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"
    printf "${BOLD}┌─ Build Images ─────────────────────────────────────────────┐${NC}\n"
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
    printf "│  ${CYAN}c${NC}) dry-run (check+diff)        ${CYAN}u${NC}) update (flake inputs)      │\n"
    printf "│  ${CYAN}o${NC}) show    (build outputs)     ${CYAN}d${NC}) diff (vs current system)  │\n"
    printf "${BOLD}└─────────────────────────────────────────────────────────────┘${NC}\n"
    printf "\n"
    printf "  ${CYAN}h${NC}) help    ${RED}q${NC}) quit\n"
    printf "\n"
    printf "  ${BOLD}Hint:${NC} long names also work — type ${GREEN}switch${NC}, ${GREEN}boot${NC}, ${GREEN}test${NC}, ${CYAN}dry-run${NC}, …\n"
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

    # Step 5: Update bootloader (rEFInd primary, GRUB chainload fallback)
    # Bootloader is owned by aa_bootloader/ — re-render menu pointing at the
    # new init path. The engine reads /nix/var/nix/profiles/system links and
    # writes /boot/efi/EFI/refind/refind.conf + /boot/grub/grub.cfg.
    log "Step 5: Re-rendering bootloader menu via aa_bootloader/..."
    INIT_PATH="$NEW_SYSTEM/init"
    log "New init path: $INIT_PATH"
    if [ -x ../aa_bootloader/build.sh ]; then
        # Current engine subcommands are deploy-all/deploy-refind/verify-boot;
        # the old 'generate' + 'deploy --target refind' names no longer exist
        # (this fresh-install path had been silently warning). NOTE: this
        # targets the RUNNING system's live ESP, matching the prior behavior —
        # a true cross-disk install to $MOUNT_ROOT is a separate, unhandled case.
        (cd ../aa_bootloader && sudo bash ./build.sh deploy-all && sudo bash ./build.sh verify-boot) \
            || warn "aa_bootloader deploy/verify reported errors — verify rEFInd manually before reboot"
    else
        warn "aa_bootloader/build.sh not found at expected relative path — skipping bootloader regen"
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
    printf "${GREEN}║  Reboot and select 'NixOS — Primary' from rEFInd menu        ║${NC}\n"
    printf "${GREEN}║  Login: diego / 1234567890                                   ║${NC}\n"
    printf "${GREEN}║                                                              ║${NC}\n"
    printf "${GREEN}║  If NixOS fails, pick 'Rescue OS — Debian' or                ║${NC}\n"
    printf "${GREEN}║  'Kali — Lab' from rEFInd to recover                         ║${NC}\n"
    printf "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
}

# ═══════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

dry_run() {
    header "NixOS Dry Run (build + diff, no apply)"
    sync_cloud_data

    if [ ! -f /etc/NIXOS ]; then
        # Not on NixOS — just evaluate the flake
        log "Not on NixOS — evaluating flake only..."
        nix flake check "$FLAKE_PATH" 2>&1 || true
        log "Flake evaluation complete"
        return
    fi

    log "Building NixOS config (dry-activate — no switch)..."
    log "CPU limits: $MAX_CORES cores, $MAX_JOBS parallel jobs"

    _BUILDSH_BOOTSTRAP_GITCONFIG="$(mktemp /tmp/buildsh-gitconfig.XXXXXX)"
    printf '[safe]\n\tdirectory = *\n' > "$_BUILDSH_BOOTSTRAP_GITCONFIG"
    _rebuild_exec "$_BUILDSH_BOOTSTRAP_GITCONFIG" dry-activate 2>&1

    if [ $? -eq 0 ]; then
        log "Dry run complete — no changes applied"
        log "Run 'switch' to apply, or 'test' to activate temporarily"
    else
        error "Dry run failed! Check errors above."
        return 1
    fi
}

# Legacy alias
check_config() { dry_run; }

update_flake() {
    header "Updating Flake Inputs"
    if [ $# -gt 0 ]; then
        log "Updating inputs: $*"
        nix flake update "$@" --flake "$FLAKE_PATH"
    else
        log "Updating all flake inputs..."
        nix flake update --flake "$FLAKE_PATH"
    fi
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
# CLOUD-DATA SYNC — copy JSON configs into flake src/modules/ before build
# ═══════════════════════════════════════════════════════════════════════════
sync_cloud_data() {
    local CD_ROOT="$SCRIPT_DIR/../../cloud-data"
    if [ ! -d "$CD_ROOT" ]; then
        warn "cloud-data not found at $CD_ROOT — skipping sync"
        return 0
    fi
    local TARGET_DIR="$FLAKE_PATH/modules"
    for f in cloud-data-disk-protection.json; do
        if [ -f "$CD_ROOT/$f" ]; then
            cp -f "$CD_ROOT/$f" "$TARGET_DIR/$f"
            log "synced $f -> $TARGET_DIR/"
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# LIVE SYSTEM REBUILD
# ═══════════════════════════════════════════════════════════════════════════
# Regenerate + verify the boot menu against the just-activated generation.
# NixOS yields bootloader management to aa_bootloader/; a rebuild that does NOT
# refresh the menu leaves rEFInd pointing at an older generation — which the
# post-switch GC then deletes, producing "initrd NOT FOUND / efi_stub failed"
# at boot (2026-06-14 Fresh Desktop incident). Non-fatal by design: it must
# never abort an already-successful rebuild, but it warns loudly if the menu
# could not be made reboot-safe.
regen_bootloader() {
    if [ ! -x ../aa_bootloader/build.sh ]; then
        warn "aa_bootloader/build.sh not found — boot menu NOT refreshed."
        warn "Run before reboot:  cd ../aa_bootloader && sudo ./build.sh deploy-all && sudo ./build.sh verify-boot"
        return 0
    fi
    log "Refreshing boot menu against the new generation (aa_bootloader deploy-all)..."
    if ( cd ../aa_bootloader && sudo bash ./build.sh deploy-all ); then
        if ( cd ../aa_bootloader && sudo bash ./build.sh verify-boot ); then
            log "Boot menu refreshed + verified — SAFE TO REBOOT."
        else
            warn "Boot menu refreshed but verify-boot is NOT green — inspect before rebooting."
        fi
    else
        warn "aa_bootloader deploy-all errored — boot menu may be stale."
        warn "Fix before reboot:  cd ../aa_bootloader && sudo ./build.sh deploy-all && sudo ./build.sh verify-boot"
    fi
}

# Rebuild the running NixOS system using nixos-rebuild switch

switch_system() {
    header "Rebuilding NixOS System"
    sync_cloud_data

    # Check if we're running on NixOS
    if [ ! -f /etc/NIXOS ]; then
        error "Not running on NixOS!"
        error "Use 'deploy' to install from another OS, or boot into NixOS first."
        return 1
    fi

    log "Rebuilding NixOS with flake: $FLAKE_PATH#surface"
    log "CPU limits: $MAX_CORES cores, $MAX_JOBS parallel jobs"
    log "This will switch to the new configuration immediately."

    _BUILDSH_BOOTSTRAP_GITCONFIG="$(mktemp /tmp/buildsh-gitconfig.XXXXXX)"
    printf '[safe]\n\tdirectory = *\n' > "$_BUILDSH_BOOTSTRAP_GITCONFIG"
    _rebuild_exec "$_BUILDSH_BOOTSTRAP_GITCONFIG" switch 2>&1

    if [ $? -eq 0 ]; then
        # Trim to last 3 generations and GC
        log "Trimming generations (keep last 3)..."
        sudo nix-env --delete-generations +3 -p /nix/var/nix/profiles/system 2>&1 || true
        nix-env --delete-generations +3 2>&1 || true
        sudo nix-collect-garbage 2>&1 || true
        log "GC complete"

        # Refresh the boot menu AFTER GC so it lists exactly the surviving
        # generations (no dangling rollback entries) and points Primary +
        # every specialisation at the just-activated generation.
        regen_bootloader

        printf "\n"
        printf "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}\n"
        printf "${GREEN}║  ${BOLD}SYSTEM REBUILD COMPLETE!${NC}${GREEN}                                   ║${NC}\n"
        printf "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}\n"
        printf "${GREEN}║  New configuration is now active.                            ║${NC}\n"
        printf "${GREEN}║  Some services may need manual restart.                      ║${NC}\n"
        printf "${GREEN}║                                                              ║${NC}\n"
        printf "${GREEN}║  To apply all changes: reboot                                ║${NC}\n"
        printf "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    else
        error "Rebuild failed! Check errors above."
        return 1
    fi
}

boot_system() {
    header "Building NixOS (Boot Only)"
    sync_cloud_data

    if [ ! -f /etc/NIXOS ]; then
        error "Not running on NixOS!"
        return 1
    fi

    log "Building NixOS config (will activate on next boot)..."
    log "CPU limits: $MAX_CORES cores, $MAX_JOBS parallel jobs"

    _BUILDSH_BOOTSTRAP_GITCONFIG="$(mktemp /tmp/buildsh-gitconfig.XXXXXX)"
    printf '[safe]\n\tdirectory = *\n' > "$_BUILDSH_BOOTSTRAP_GITCONFIG"
    _rebuild_exec "$_BUILDSH_BOOTSTRAP_GITCONFIG" boot 2>&1

    if [ $? -eq 0 ]; then
        # `nixos-rebuild boot` sets the next-boot generation — the menu MUST
        # be refreshed to point at it, or reboot lands on the old/broken entry.
        regen_bootloader
        log "Build complete! Reboot to activate new configuration."
    else
        error "Build failed!"
        return 1
    fi
}

test_system() {
    header "Testing NixOS Configuration"
    sync_cloud_data

    if [ ! -f /etc/NIXOS ]; then
        error "Not running on NixOS!"
        return 1
    fi

    log "Building and activating temporarily (reverts on reboot)..."
    log "CPU limits: $MAX_CORES cores, $MAX_JOBS parallel jobs"

    _BUILDSH_BOOTSTRAP_GITCONFIG="$(mktemp /tmp/buildsh-gitconfig.XXXXXX)"
    printf '[safe]\n\tdirectory = *\n' > "$_BUILDSH_BOOTSTRAP_GITCONFIG"
    _rebuild_exec "$_BUILDSH_BOOTSTRAP_GITCONFIG" test 2>&1

    if [ $? -eq 0 ]; then
        log "Test activation complete!"
        log "This configuration will revert on next reboot."
        log "Run 'switch' to make it permanent."
    else
        error "Test build failed!"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# REMOTE BUILD (GHA) + LOCAL ACTIVATE — never run the freeze-prone eval locally
# ═══════════════════════════════════════════════════════════════════════════
# The 8GB Surface cannot run `nixos-rebuild` without thrashing into a freeze
# (the eval over-commits RAM). So the eval+build happens on a GHA runner
# (`ci-build`), and the laptop only IMPORTS the prebuilt closure and activates
# it (`pull` = Phase 2 only, no eval) — which can never freeze.

# ci-build — run on a GHA ubuntu runner. Build the system toplevel, export its
# full closure as a zstd tarball into dist-ci/ for upload as a workflow artifact.
# restore_boot_cache <dist-ci-dir> — pull the prebuilt linux-surface kernel+initrd
# closure from the GHCR boot-cache and import it into the local /nix/store BEFORE
# `nix build`, so the closure build finds the kernel present instead of compiling
# it from source (~2h > the 120m GHA wall — the reason every prior desktop_nixos
# run was cancelled). Producer: 1_workflows/src/cicd/ship-boot-cache.yml publishes
# ghcr.io/<owner>/unix-boot-cache:latest as a `nix copy` file-store under /boot-cache.
# Non-fatal: any failure just falls back to compiling.
restore_boot_cache() {
    local tmp="$1/.boot-cache"
    local owner="${GHCR_OWNER:-diegonmarcos}"
    local img="ghcr.io/${owner}/unix-boot-cache:latest"
    command -v docker >/dev/null 2>&1 || { warn "docker absent — skipping boot-cache restore (kernel will compile)"; return 0; }
    if [ -n "${GHCR_TOKEN:-}" ]; then
        printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "${GHCR_USER:-x}" --password-stdin >/dev/null 2>&1 \
            || warn "ghcr login failed — trying anonymous pull"
    fi
    log "Restoring linux-surface kernel from $img …"
    if ! docker pull -q "$img" >/dev/null 2>&1; then
        warn "boot-cache pull failed ($img) — kernel will be compiled from source"
        return 0
    fi
    rm -rf "$tmp"; mkdir -p "$tmp/unpacked"
    # The image is FROM scratch with no CMD, so `docker create`/`export` errors
    # ("no command specified"). Use `docker save` (image tarball) and extract its
    # layer blobs — the /boot-cache COPY lands at $tmp/boot-cache. jq-free: try to
    # untar every blob; the config JSON fails harmlessly, the layer tar wins.
    docker save "$img" -o "$tmp/img.tar" 2>/dev/null || { warn "docker save failed — will compile"; return 0; }
    tar -xf "$tmp/img.tar" -C "$tmp/unpacked" 2>/dev/null || { warn "image untar failed — will compile"; return 0; }
    find "$tmp/unpacked" -type f | while read -r blob; do tar -xf "$blob" -C "$tmp" 2>/dev/null || true; done
    rm -rf "$tmp/unpacked" "$tmp/img.tar"
    if [ -d "$tmp/boot-cache" ]; then
        # 2026-07-22 ROOT-CAUSE FIX: `nix copy --all` is atomic — ONE bogus
        # path in the cache (a literal '…-x' garbage narinfo shipped into
        # unix-boot-cache) aborted the whole restore, so EVERY CI run
        # recompiled the linux-surface kernel (~140 min burned per run since
        # the cache was poisoned). Copy per-path instead: skip garbage, a
        # single bad path can no longer kill the kernel restore.
        local _sp _ok=0 _bad=0
        for _sp in $(sed -n 's/^StorePath: //p' "$tmp/boot-cache"/*.narinfo 2>/dev/null); do
            case "$_sp" in
                *-x|*'?'*|*' '*) warn "skipping bogus cache path: $_sp"; _bad=$((_bad+1)); continue ;;
            esac
            if nix copy --no-check-sigs --from "file://$tmp/boot-cache" "$_sp" \
                 --extra-experimental-features "nix-command flakes" 2>/dev/null; then
                _ok=$((_ok+1))
            else
                warn "boot-cache path failed (non-fatal): $_sp"; _bad=$((_bad+1))
            fi
        done
        if [ "$_ok" -gt 0 ]; then
            log "boot-cache restored $_ok paths ($_bad skipped/failed) → kernel should NOT compile"
        else
            warn "boot-cache restored nothing ($_bad bad) — kernel will compile"
        fi
    else
        warn "boot-cache payload missing in image — kernel will compile"
    fi
    rm -rf "$tmp"
}

ci_build() {
    header "CI: build + export desktop system closure"
    local out="$SCRIPT_DIR/dist-ci"
    rm -rf "$out"; mkdir -p "$out"

    # Free GHA-runner disk — a 17G closure + 7G export won't fit in the default
    # ~21G root. Only touch the runner's preinstalled bloat, never a real system.
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        log "Freeing GHA runner disk…"
        sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
                    /opt/hostedtoolcache/CodeQL /usr/local/share/boost 2>/dev/null || true
    fi

    # Seed the store with the prebuilt kernel so the build below doesn't compile it.
    restore_boot_cache "$out"

    log "Building toplevel (linux-surface kernel restored from boot-cache → not rebuilt)…"
    nix build "$FLAKE_PATH#nixosConfigurations.surface.config.system.build.toplevel" \
        --out-link "$out/result" -L --accept-flake-config \
        --extra-experimental-features "nix-command flakes" || { error "ci build failed"; return 1; }

    local sys; sys=$(readlink -f "$out/result")
    basename "$sys" > "$out/toplevel.name"
    echo "$sys" > "$out/toplevel.path"

    log "Exporting closure → zstd tarball…"
    nix-store --export $(nix-store -qR "$sys") | zstd -T0 -15 > "$out/system-closure.nar.zst"

    # ── Closure DIFF export (2026-07-22) ────────────────────────────────────
    # The laptop commits the store-path list it already has
    # (dist-ci-have/have-paths.txt). Export ONLY the missing paths as a small
    # separate artifact — home wifi must NEVER download a 7GB bundle again
    # (the layered GHCR image hides a 7.1GB mono-layer: >maxLayers store
    # paths get lumped, and one blob restart-from-zero can't survive flaky
    # wifi). The diff is typically a few hundred MB at most.
    local _have="$SCRIPT_DIR/dist-ci-have/have-paths.txt"
    local _dout="$SCRIPT_DIR/dist-ci-diff"
    rm -rf "$_dout"; mkdir -p "$_dout"
    if [ -f "$_have" ]; then
        nix-store -qR "$sys" | sort > "$out/want-paths.txt"
        local _missing; _missing=$(comm -23 "$out/want-paths.txt" <(sort "$_have"))
        if [ -n "$_missing" ]; then
            log "Diff export: $(printf '%s\n' "$_missing" | wc -l) paths missing on laptop"
            nix-store --export $_missing | zstd -T0 -15 > "$_dout/closure-diff.nar.zst"
        else
            log "Diff export: laptop already has every path (empty diff)"
            : > "$_dout/closure-diff.nar.zst"
        fi
        cp "$out/toplevel.name" "$_dout/"
        log "diff artifact: $(du -h "$_dout/closure-diff.nar.zst" | cut -f1)"
    else
        warn "no dist-ci-have/have-paths.txt — skipping diff export"
        cp "$out/toplevel.name" "$_dout/" 2>/dev/null || true
    fi

    rm -f "$out/result"
    log "Done: $(du -h "$out/system-closure.nar.zst" | cut -f1) → $out/"

    # ── Stage 1: layered GHCR cache (INCREMENTAL delivery) ──────────────────
    # Additive + NON-FATAL: the nar.zst above stays the active mechanism until
    # `pull_remote` learns to consume this. Mirrors
    # ba_flakes_desktop/build.sh's cmd_ci_build exactly (same rationale: one
    # layer per store path via dockerTools.buildLayeredImage, skopeo skips
    # blobs already present in the registry). Guarded by GHCR_PUSH=1.
    if [ "${GHCR_PUSH:-0}" = "1" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
        local _img="${SYSTEM_CACHE_IMAGE:-ghcr.io/diegonmarcos/unix-system-cache}"
        log "building + pushing layered system cache image → ${_img}:latest (incremental)"
        # GHA Ubuntu runners ship /etc/containers/registries.conf in the LEGACY
        # v1 format, which skopeo 1.23 refuses to load ("must be in v2 format
        # but is in v1") — the 2026-07-09 silent-failure root cause that left
        # the incremental cache image unpublished for weeks, forcing every
        # `switch` to pull the full 5.6GB nar.zst. Point skopeo at an ephemeral
        # empty v2 config: fully-qualified docker:// refs need no registries.
        local _reg="$out/registries.conf"
        printf 'unqualified-search-registries = []\n' > "$_reg"
        if nix build "$FLAKE_PATH#packages.x86_64-linux.system-cache-image" \
             --accept-flake-config --out-link "$out/system-cache-image" \
             --extra-experimental-features "nix-command flakes"; then
            CONTAINERS_REGISTRIES_CONF="$_reg" \
            nix run --extra-experimental-features "nix-command flakes" nixpkgs#skopeo -- \
                copy --dest-creds "x:${GITHUB_TOKEN}" \
                "docker-archive:$(readlink -f "$out/system-cache-image")" \
                "docker://${_img}:latest" \
                && log "pushed layered system cache → ${_img}:latest" \
                || warn "skopeo push failed (non-fatal — nar.zst artifact still delivered)"
        else
            warn "system-cache-image build failed (non-fatal — nar.zst still delivered)"
        fi
        rm -f "$out/system-cache-image"
    fi
}

# ghcr_pull_layered <image:tag> — materialise a layered GHCR closure image's
# /nix/store paths onto the real local store, skipping any path already
# present. Genuine incremental: unchanged layers are never even pulled by
# `docker pull`, and unchanged store paths are never re-copied locally.
# Returns 1 on ANY failure (docker missing, image missing, pull failure) —
# additive, caller falls back to nar.zst. Mirrors
# ba_flakes_desktop/build.sh's ghcr_pull_layered() exactly.
ghcr_pull_layered() {
    local img="$1"
    command -v docker >/dev/null 2>&1 || return 1
    log "Trying layered GHCR pull: $img …"
    # BUG FIX 2026-07-19: this used to redirect docker pull's entire output
    # to /dev/null, so the konsole window showed nothing for the whole pull
    # (looked frozen even though it was transferring real bytes). Piping
    # through `cat` forces docker's isatty() check to fail, which switches it
    # from the interactive \r-overwriting bar (invisible to grep/log files,
    # only visible live on a real terminal) to classic one-line-per-layer
    # streaming text (Pulling fs layer / Downloading [==>] N/M / Pull
    # complete) — real byte-level verbosity that lands in the log AND stays
    # visible in the konsole window.
    # `cat` itself block-buffers (~4K) when its own stdout is a pipe rather
    # than a terminal, so early per-layer lines sat invisible until the
    # buffer filled or the pull finished. stdbuf -oL forces line buffering
    # through the pipe so each line lands in the log/window as it's printed.
    docker pull "$img" 2>&1 | stdbuf -oL cat
    [ "${PIPESTATUS[0]}" -eq 0 ] || { warn "GHCR image unavailable — falling back to nar.zst"; return 1; }

    local tmp="system-cache-extract-$$"
    docker create --name "$tmp" "$img" >/dev/null 2>&1 || { warn "docker create failed — falling back to nar.zst"; return 1; }

    local _sudo="/run/wrappers/bin/sudo"; [ -x "$_sudo" ] || _sudo="sudo"
    local copied=0 skipped=0 p host
    for p in $(docker run --rm "$img" sh -c 'ls /nix/store' 2>/dev/null); do
        host="/nix/store/$p"
        if [ -e "$host" ]; then
            skipped=$((skipped + 1))
            continue
        fi
        if $_sudo sh -c "docker cp '$tmp:/nix/store/$p' - 2>/dev/null | tar -x -C /nix/store" 2>/dev/null && [ -e "$host" ]; then
            copied=$((copied + 1))
        fi
    done
    docker rm "$tmp" >/dev/null 2>&1 || true
    log "Layered pull: $copied copied, $skipped already present"
    [ "$copied" -gt 0 ] || [ "$skipped" -gt 0 ]
}

# pull [artifact-dir] — run on the Surface. Import a GHA-built closure tarball
# and activate it. NO nix eval, NO build → physically cannot freeze the machine.
# Default artifact-dir is dist-ci/ (e.g. after `gh run download -n nixos-surface-closure -D dist-ci`).
pull_remote() {
    header "Activate prebuilt closure (no eval — cannot freeze)"
    # ── ORCHESTRATOR (2026-07-22 refactor) ───────────────────────────────
    # The pipeline lives in src/scripts/steps/ — one script per step, each
    # independently runnable, hand-off via dist-ci/toplevel.name:
    #   10-fetch-diff.sh        gh diff artifact (DIFF-ONLY: 7GB forbidden)
    #   20-import-diff.sh       nix-store --import (empty diff = no-op)
    #   30-verify-closure.sh    full reference-graph completeness proof
    #   40-activate.sh          profile set + switch-to-configuration
    #   45-bootloader.sh        aa_bootloader deploy-all + verify-boot
    #   50-refresh-inventory.sh have-paths self-refresh + push
    # Step exit 3 = "already active" → success, stop early.
    local steps="$SCRIPT_DIR/src/scripts/steps" _s _rc
    for _s in 10-fetch-diff 20-import-diff 30-verify-closure 40-activate 45-bootloader 50-refresh-inventory; do
        log "── STEP $_s ──"
        bash "$steps/$_s.sh"; _rc=$?
        if [ "$_rc" -eq 3 ]; then log "Pipeline stopped early: already active."; return 0; fi
        if [ "$_rc" -ne 0 ]; then error "STEP $_s failed (rc=$_rc) — pipeline aborted."; return "$_rc"; fi
    done
    log "Switch pipeline complete."
    return 0
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

        # Normalise: lowercase, trim. Accept short keys, long names, dashes and spaces.
        choice_norm=$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

        case "$choice_norm" in
            s|switch|rebuild)
                # Interactive menu mirrors the CLI default: pull (GHA closure, no eval)
                pull_remote ""
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            switch-local|local)
                switch_system
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            b|boot)
                boot_system
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            t|test)
                test_system
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            1|raw|build-raw)
                build_raw
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            2|iso|build-iso)
                build_iso
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            3|qcow|qcow2|build-qcow)
                build_qcow
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            4|vm-runner|build-vm)
                build_vm
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            5|burn|burn-usb)
                burn_to_usb
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            6|vm|create-vm)
                printf "${BOLD}Enter VM name (default: nixos-test):${NC} "
                read -r vm_name
                create_vm "$vm_name"
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            7|deploy)
                deploy_existing
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            i|install)
                install_full
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            c|check|dry-run|dryrun)
                dry_run
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            u|update)
                update_flake
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            o|show|outputs)
                show_outputs
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            d|diff)
                diff_system
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            h|help|-h|--help|\?)
                clear
                # Show documentation from script header
                head -200 "$0" | grep "^#" | sed 's/^#//' | less
                ;;
            q|quit|exit)
                printf "\n"
                log "Goodbye!"
                exit 0
                ;;
            *)
                warn "Invalid option: '$choice'"
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

    # Normalise: lowercase, trim. Same alias set as the interactive menu.
    cli_cmd=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

    # ── ALWAYS-VISIBLE KONSOLE + ALERT + PROGRESS BAR (2026-07-18/19, engine-level, declarative) ──
    # Diego was repeatedly blindsided by switch/pull running headless — no
    # popup, no progress bar, no terminal he could see. Never manually wrap
    # this again: the FIRST time an interactive command runs (guarded by
    # BUILD_SH_KONSOLE_WRAPPED=1 against infinite re-exec) with a real desktop
    # session present, this block fires ALL THREE defaults declared in
    # konsole_wrap: (1) a notify-send alert, (2) a self-relaunch inside
    # `konsole --hold` so there is ALWAYS a visible terminal with live output,
    # (3) a kdialog progress bar tailing the same log. Never fires in CI or
    # headless (DISPLAY/DBUS unset) — falls through to plain execution there.
    # 2026-07-19 BUG FIX: bare "$0" has no meaning inside konsole's own
    # default cwd (relative paths die instantly, looked like a silent hang —
    # was actually crash-on-launch). Resolve to $SCRIPT_DIR/build.sh + pass
    # --workdir explicitly.
    _sp_json="$FLAKE_PATH/modules/cloud-data-system-protection.json"
    if [ -z "${BUILD_SH_KONSOLE_WRAPPED:-}" ] && [ -z "${SWITCH_ISOLATED:-}" ] \
       && [ "${GITHUB_ACTIONS:-}" != "true" ] && command -v jq >/dev/null 2>&1 \
       && [ -f "$_sp_json" ] \
       && [ "$(jq -r '.konsole_wrap.enable // false' "$_sp_json")" = "true" ] \
       && jq -e --arg c "$cli_cmd" '.konsole_wrap.commands | index($c)' "$_sp_json" >/dev/null 2>&1 \
       && [ -n "${DISPLAY:-}" ] && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] \
       && command -v konsole >/dev/null 2>&1; then

        if [ "$(jq -r '.konsole_wrap.notify_send // false' "$_sp_json")" = "true" ] \
           && command -v notify-send >/dev/null 2>&1; then
            notify-send -u normal -i nix-snowflake-white \
                "build.sh $cli_cmd starting" "$FLAKE_PATH — opening Konsole with full log"
        fi

        if [ "$(jq -r '.konsole_wrap.kdialog_progress // false' "$_sp_json")" = "true" ] \
           && command -v kdialog >/dev/null 2>&1; then
            export BUILD_SH_KDIALOG_LOG="$LOG_DIR/build-konsole-$(date +%Y%m%d-%H%M%S).log"
            mkdir -p "$LOG_DIR"
            : > "$BUILD_SH_KDIALOG_LOG"
            # 2026-07-21: the old inline watcher was a lazy 4-step bar with no
            # data (just setValue 1/2/3 + last log line). Replaced by
            # src/scripts/switch-progress.sh — a real dialog showing overall %,
            # current stage + per-stage fill, layers done/total (from the image
            # manifest), elapsed, layers/min rate, ETA, and downloaded GB. It
            # parses BUILD_SH_KDIALOG_LOG live and tracks liveness via `kill -0`
            # on $$ (captured pre-exec — `exec` keeps the PID, so this shell IS
            # the konsole that runs the switch). Backgrounded + disowned so it
            # never blocks the exec below.
            _watch_pid=$$
            _prog_img="${SYSTEM_CACHE_IMAGE:-ghcr.io/diegonmarcos/unix-system-cache}:latest"
            _prog_sh="$SCRIPT_DIR/src/scripts/switch-progress.sh"
            if [ -f "$_prog_sh" ]; then
                setsid bash "$_prog_sh" "$BUILD_SH_KDIALOG_LOG" "$_prog_img" "$_watch_pid" \
                    </dev/null >/dev/null 2>&1 & disown
            fi
        fi

        # 2026-07-21 ROOT-CAUSE FIX: the konsole used to run build.sh directly,
        # but build.sh's REAL work re-execs into `systemd-run --wait` (isolation
        # block below), and a systemd unit's stdout goes to the JOURNAL — never
        # back to this terminal. So the konsole window went dark after the first
        # few lines while everything happened invisibly in the unit. The unit
        # DOES tee everything to LOG_FILE (=BUILD_SH_KDIALOG_LOG, propagated via
        # --setenv), so instead of running the muted script we run the switch in
        # the background and `tail -F` that shared log in the foreground — the
        # window now shows genuine byte-per-byte live output regardless of how
        # many times build.sh re-execs itself.
        exec env BUILD_SH_KONSOLE_WRAPPED=1 LOG_FILE="${BUILD_SH_KDIALOG_LOG:-}" \
            konsole --workdir "$SCRIPT_DIR" --hold -e bash -c '
                _log="$1"; shift
                : > "$_log"
                tail -n +1 -F "$_log" &
                _tp=$!
                "$@" >/dev/null 2>&1
                _ec=$?
                sleep 1
                kill "$_tp" 2>/dev/null
                exit "$_ec"
            ' _ "${BUILD_SH_KDIALOG_LOG:-$LOG_DIR/build-konsole-$(date +%Y%m%d-%H%M%S).log}" \
              "$SCRIPT_DIR/build.sh" "$@"
    fi

    # ── FREEZE-SAFE ISOLATION (2026-07-10 v3.1) ──────────────────────────────
    # A heavy switch/pull (6GB closure download + nix-store import) MUST NOT run
    # in the desktop's own cgroup (app.slice under user-1000.slice) — its memory
    # pressure thrashes the compositor and freezes the box (happened 5× on
    # 2026-07-10). Re-exec the whole invocation, as this user, into workload.slice
    # (a SYSTEM slice isolated from the desktop) bounded by switch_isolation.*.
    # If the transfer balloons past the cap, oomd kills the SWITCH there; the
    # desktop is untouched. SWITCH_ISOLATED=1 guards against infinite re-exec.
    _sp_json="$FLAKE_PATH/modules/cloud-data-system-protection.json"
    if [ -z "${SWITCH_ISOLATED:-}" ] && command -v systemd-run >/dev/null 2>&1 \
       && command -v jq >/dev/null 2>&1 && [ -f "$_sp_json" ] \
       && [ "$(jq -r '.switch_isolation.enable // false' "$_sp_json")" = "true" ]; then
        case "$cli_cmd" in
            s|switch|rebuild|pull)
                # Only isolate the freeze-prone REMOTE path (pull). `switch local`
                # is a local eval that this 8GB box shouldn't run anyway; leave it
                # to fail loudly rather than isolate an already-forbidden path.
                if [ "$cli_cmd" = "switch" ] && [ "${2:-pull}" = "local" ]; then :; else
                    _iso_slice="$(jq -r '.switch_isolation.slice // "workload.slice"' "$_sp_json")"
                    _iso_mm="$(jq -r '.switch_isolation.memory_max // "3G"' "$_sp_json")"
                    _iso_sm="$(jq -r '.switch_isolation.swap_max // "6G"' "$_sp_json")"
                    _iso_sudo="/run/wrappers/bin/sudo"; [ -x "$_iso_sudo" ] || _iso_sudo="sudo"
                    log "Isolating switch into $_iso_slice (mem≤$_iso_mm swap≤$_iso_sm) — the desktop can NOT be frozen by this transfer."
                    # notify-send (2026-07-18): switches run silent for minutes with no
                    # popup/progress-bar — Diego has repeatedly been blindsided by a
                    # background `switch` he had no visibility into. Fire start + finish/fail.
                    command -v notify-send >/dev/null 2>&1 && notify-send -u normal -i nix-snowflake-white \
                        "build.sh $cli_cmd starting" "isolated in $_iso_slice (mem≤$_iso_mm) — $FLAKE_PATH"
                    _iso_start="$(date +%s)"
                    "$_iso_sudo" systemd-run --slice="$_iso_slice" --unit=nixos-switch-isolated \
                        --uid="$(id -u)" --gid="$(id -g)" --wait --collect --quiet \
                        -p MemoryHigh="$_iso_mm" -p MemoryMax="$_iso_mm" -p MemorySwapMax="$_iso_sm" \
                        --setenv=SWITCH_ISOLATED=1 --setenv=HOME="$HOME" --setenv=PATH="$PATH" \
                        --setenv=LOG_FILE="$LOG_FILE" \
                        --working-directory="$SCRIPT_DIR" \
                        "$0" "$@"
                    _iso_rc=$?
                    _iso_elapsed=$(( $(date +%s) - _iso_start ))
                    if [ "$_iso_rc" -eq 0 ]; then
                        command -v notify-send >/dev/null 2>&1 && notify-send -u normal -i emblem-default \
                            "build.sh $cli_cmd done (${_iso_elapsed}s)" "$FLAKE_PATH"
                    else
                        command -v notify-send >/dev/null 2>&1 && notify-send -u critical -i emblem-important \
                            "build.sh $cli_cmd FAILED (${_iso_elapsed}s, exit $_iso_rc)" "$FLAKE_PATH"
                    fi
                    exit "$_iso_rc"
                fi
                ;;
        esac
    fi

    case "$cli_cmd" in
        s|switch|rebuild)
            # switch {pull|local} — pull is the DEFAULT: this 8GB machine must
            # not eval locally (GHA builds the closure; here we import+activate).
            # 2026-07-02: six local-eval attempts OOM-froze the desktop; the
            # designed flow was always GHA build → build.sh pull.
            case "${2:-pull}" in
                pull)  pull_remote "$3" ;;
                local) switch_system ;;
                *)
                    error "Unknown switch mode: $2"
                    printf "Usage: %s switch [pull|local]   (default: pull — GHA closure import, no local eval)\n" "$0"
                    exit 1
                    ;;
            esac
            ;;
        b|boot)
            boot_system
            ;;
        t|test)
            test_system
            ;;
        ci-build)
            ci_build
            ;;
        pull|switch-remote)
            pull_remote "$2"
            ;;
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
        1|raw|build-raw)
            build_raw
            ;;
        2|iso|build-iso)
            build_iso
            ;;
        3|qcow|qcow2|build-qcow)
            build_qcow
            ;;
        4|vm-runner|build-vm)
            build_vm
            ;;
        5|burn|burn-usb)
            burn_to_usb "$2"
            ;;
        6|vm|create-vm)
            create_vm "$2"
            ;;
        7|deploy)
            deploy_existing
            ;;
        i|install)
            install_full
            ;;
        c|check|dry-run|dryrun)
            dry_run
            ;;
        u|update)
            update_flake "${@:2}"
            ;;
        o|show|outputs)
            show_outputs
            ;;
        d|diff)
            diff_system
            ;;
        h|help|-h|--help|\?)
            clear
            head -200 "$0" | grep "^#" | sed 's/^#//' | less
            ;;
        q|quit|exit)
            exit 0
            ;;
        *)
            printf "${BOLD}NixOS Bifrost Build System${NC}\n\n"
            printf "Usage: %s [command]\n" "$0"
            printf "       %s            (interactive menu)\n\n" "$0"
            printf "${BOLD}Live System (NixOS only):${NC}\n"
            printf "  s | switch [pull|local]   Switch to new config (DEFAULT pull: import GHA closure, no eval;\n"
            printf "                            local: full eval on this machine — pressures 8GB RAM)\n"
            printf "  b | boot                  Build config, activate on next boot\n"
            printf "  t | test                  Test config (reverts on reboot)\n"
            printf "  ci-build                  [GHA] Build + export system closure tarball → dist-ci/\n"
            printf "  pull [dir]                Import a GHA-built closure + activate (NO eval — never freezes)\n"
            printf "\n"
            printf "${BOLD}Build Images:${NC}\n"
            printf "  1 | raw   | build raw     Build raw EFI disk image\n"
            printf "  2 | iso   | build iso     Build bootable ISO\n"
            printf "  3 | qcow  | build qcow    Build QCOW2 VM image\n"
            printf "  4 | vm-runner | build vm  Build VM runner script\n"
            printf "\n"
            printf "${BOLD}Deploy:${NC}\n"
            printf "  5 | burn [device]         Burn raw image to USB\n"
            printf "  6 | vm   [name]           Create VM from QCOW2\n"
            printf "  7 | deploy                Deploy to existing partitions (safe)\n"
            printf "  i | install               Full installation (WIPES DISK)\n"
            printf "\n"
            printf "${BOLD}Utilities:${NC}\n"
            printf "  c | check | dry-run       Build + diff without applying (safe)\n"
            printf "  u | update [input...]     Update flake inputs (all, or named only)\n"
            printf "  o | show                  Show available outputs\n"
            printf "  d | diff                  Diff with current system\n"
            printf "  h | help                  Show this help\n"
            printf "  q | quit | exit           Exit\n"
            printf "\n"
            printf "${BOLD}Environment:${NC}\n"
            printf "  TARGET_DISK=/dev/sda %s install\n" "$0"
            printf "\n"
            [ -n "$cli_cmd" ] && exit 1 || exit 0
            ;;
    esac
else
    main
fi
