# NixOS Host Architecture

> **Device**: Surface Pro 8 (Intel Tiger Lake, 8GB RAM, 256GB NVMe)
> **OS**: NixOS 24.11 - Minimal + User Agnostic
> **Boot**: GRUB (LUKS2 + USB keyfile unlock)
> **Status**: Dual-boot with Kubuntu
> **Philosophy**: Minimal NixOS + Shared Tools + Detachable Homes

---

## CRITICAL: Build & Store Architecture

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                        ONE STORE - NO DUPLICATION                              ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║                                                                                ║
║   THE ONLY NIX STORE: @nixos/nix                                              ║
║                                                                                ║
║   ┌─────────────────────────────────────────────────────────────────────────┐ ║
║   │ Kubuntu (Build Host)                                                     │ ║
║   │   - Has NO local /nix store                                             │ ║
║   │   - Mounts @nixos/nix as /nix before building                           │ ║
║   │   - Runs nix-daemon against @nixos/nix                                  │ ║
║   │   - All builds go directly into @nixos/nix                              │ ║
║   │   - Kernel compiled ONCE, cached in @nixos/nix FOREVER                  │ ║
║   │   - Output images (.iso, .raw, .qcow) saved to @shared/images/          │ ║
║   └─────────────────────────────────────────────────────────────────────────┘ ║
║                                    │                                           ║
║                                    ▼                                           ║
║   ┌─────────────────────────────────────────────────────────────────────────┐ ║
║   │ @nixos/nix (THE STORE)                                                   │ ║
║   │   - Contains ALL nix derivations                                        │ ║
║   │   - linux-surface kernel (2h compile - CACHED HERE!)                    │ ║
║   │   - NixOS system closure                                                │ ║
║   │   - Mounted as /nix when NixOS boots                                    │ ║
║   │   - Mounted as /nix on Kubuntu when building                            │ ║
║   └─────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                ║
║   ┌─────────────────────────────────────────────────────────────────────────┐ ║
║   │ @shared (NOT A STORE - Large Files Only)                                 │ ║
║   │   - images/      : Built .iso, .raw, .qcow files                        │ ║
║   │   - tools/       : Shared CLI tools                                     │ ║
║   │   - data/        : Cache, containers, VM images                         │ ║
║   │   - waydroid/    : Android base image                                   │ ║
║   └─────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

**Build Flow:**
```bash
# 1. build.sh mounts @nixos/nix as /nix
sudo mount -o subvol=@nixos/nix /dev/mapper/luks_pool /nix

# 2. nix-daemon runs against @nixos/nix
sudo nix-daemon &

# 3. Build - kernel is cached in @nixos/nix
nix build .#nixosConfigurations.surface...

# 4. Output image saved to @shared
cp result/* /mnt/shared/images/
```

**Why This Matters:**
- Kernel takes 2+ hours to compile
- With ONE store, kernel is built ONCE
- Future builds reuse cached kernel from @nixos/nix
- No wasted rebuilds, no duplicate stores

---

## Overview

**Extremely minimal, user-agnostic NixOS** with full impermanence (tmpfs root).

### Design Principles

1. **User Agnostic** - No `/persist` subvolume. Truly stateless OS.
2. **Detachable Homes** - @home-* subvolumes can move to any NixOS
3. **Shared Tools** - All dev tools in @shared/tools/
4. **Per-User Credentials** - WiFi passwords and Bluetooth pairings travel with user's home

```
+===============================================================================+
|                    NIXOS SURFACE PRO 8 - USER AGNOSTIC                        |
+===============================================================================+

+-------------------------------------------------------------------------------+
|                              DESIGN PHILOSOPHY                                 |
|-------------------------------------------------------------------------------+
|                                                                               |
|   NixOS provides ONLY:              @shared (cross-user):                     |
|   +---------------------+           +----------------------------------+      |
|   | SDDM Display Manager|           | tools/   : CLI tools + scripts   |      |
|   | KDE Plasma 6        |           | configs/ : shared configurations |      |
|   | GNOME               |           | data/    : cache, containers, vm |      |
|   | Openbox             |           | waydroid/: Android base image    |      |
|   | Waydroid            |           | mnt/     : external drive mounts |      |
|   | Kiosk modes         |           +----------------------------------+      |
|   +---------------------+                                                     |
|           |                         @home-* (per-user, PORTABLE):             |
|           |                         +----------------------------------+      |
|           |                         | WiFi passwords (in keyring)      |      |
|           |                         | Bluetooth pairings               |      |
|           +------------------------>| Fully detachable to ANY NixOS    |      |
|                                     +----------------------------------+      |
|                                                                               |
|   NO /persist subvolume - truly stateless OS                                 |
|                                                                               |
+-------------------------------------------------------------------------------+
```

---

## BTRFS Subvolume Structure

```
/dev/mapper/pool (BTRFS - 80GB shared pool with zstd compression)
|
+-- @nixos/                           # NixOS system (minimal, stateless)
|   +-- nix/                          # Nix store (~10-15GB minimal)
|       +-- store/                    # Only essential packages
|       +-- var/                      # Nix daemon state
|
+-- @home-diego/                      # Diego's home (FULLY PORTABLE)
|   +-- .config/                      # App configs
|   +-- .local/                       # Local data
|   |   +-- share/
|   |       +-- keyrings/             # GNOME Keyring (WiFi passwords)
|   |       +-- bluetooth/            # Bluetooth pairings (symlinked at login)
|   +-- .ssh/                         # SSH keys
|   +-- .gnupg/                       # GPG keys
|   +-- Documents/
|   +-- Downloads/
|   +-- Projects/
|   +-- waydroid/                     # Diego's Android apps/data
|
+-- @home-guest/                      # Guest home (FULLY PORTABLE)
|   +-- .config/
|   +-- .local/
|   |   +-- share/
|   |       +-- keyrings/             # Guest's WiFi passwords
|   |       +-- bluetooth/            # Guest's Bluetooth pairings
|   +-- .cache/
|   +-- Downloads/
|   +-- waydroid/                     # Guest's Android apps/data
|
+-- @shared/                          # Shared between OSes and users
    +-- .swapfile (8GB)
    |
    +-- tools/                        # CLI TOOLS + SCRIPTS
    |   +-- base/bin/                 # curl, wget, git, htop, ripgrep
    |   +-- dev/bin/                  # gcc, clang, cargo, go, node
    |   +-- data/bin/                 # python, pandas, jupyter
    |   +-- devops/bin/               # kubectl, terraform, ansible
    |   +-- scripts/                  # Utility scripts
    |
    +-- configs/                      # SHARED CONFIGURATIONS
    |   +-- (vpn, app configs, etc.)
    |
    +-- data/                         # PERSISTENT DATA/STATE
    |   +-- cache/
    |   |   +-- cargo/
    |   |   +-- npm/
    |   |   +-- pip/
    |   |   +-- go/
    |   +-- containers/
    |   |   +-- docker/               # Docker data-root
    |   |   +-- podman/               # Podman graphroot
    |   +-- vm/                       # libvirt VM images
    |   +-- fonts/                    # Custom fonts
    |   +-- themes/                   # GTK/Qt themes
    |
    +-- waydroid/                     # Android OS image (~3GB)
    |
    +-- mnt/                          # External drive mount points
```

---

## User Agnostic Design

### What "User Agnostic" Means

| Aspect | Traditional NixOS | This Design |
|--------|-------------------|-------------|
| `/persist` subvolume | Required | **None** |
| SSH host keys | Persisted | Ephemeral (regenerate on boot) |
| machine-id | Persisted | Hardcoded in config |
| WiFi passwords | /etc/NetworkManager | **User's keyring** (~/.local/share/keyrings/) |
| Bluetooth pairings | /var/lib/bluetooth | **User's home** (~/.local/share/bluetooth/) |
| User homes | Bind mounts | Dedicated subvolumes |
| Home portability | Tied to system | **Fully detachable with all credentials** |

### Benefits

1. **Plug @home-diego into ANY NixOS** - Just mount the subvolume, WiFi/Bluetooth comes with it
2. **Per-user credentials** - Each user owns their WiFi passwords and Bluetooth pairings
3. **True separation** - OS is disposable, all user data is portable
4. **Minimal attack surface** - Nothing persists in root filesystem
5. **No credential conflicts** - Users don't share or overwrite each other's connections

### Trade-offs

1. SSH clients see "host key changed" warnings (acceptable for personal device)
2. WiFi networks must be re-authenticated per user (each user has their own password storage)
3. Bluetooth devices must be paired per user

---

## Runtime Filesystem (After Boot)

```
/  (tmpfs 2GB - WIPED EVERY REBOOT)
|
+-- /nix ---------------------------> btrfs subvol=@nixos/nix
|   +-- /nix/store                    (persistent, minimal packages)
|
+-- /etc ---------------------------> tmpfs (ephemeral)
|   +-- machine-id                    (hardcoded in config)
|   +-- ssh/                          (keys regenerate on boot)
|
+-- /var ---------------------------> tmpfs (ephemeral)
|   +-- lib/bluetooth --------------> symlink to $HOME/.local/share/bluetooth (at login)
|
+-- /home/diego --------------------> btrfs subvol=@home-diego
|   +-- .local/share/
|   |   +-- keyrings/                (WiFi passwords - GNOME Keyring)
|   |   +-- bluetooth/               (Bluetooth pairings - symlinked to /var/lib/bluetooth)
|   |   +-- waydroid/                (Diego's Android apps/data)
|
+-- /home/guest --------------------> btrfs subvol=@home-guest
|   +-- .local/share/
|   |   +-- keyrings/                (Guest's WiFi passwords)
|   |   +-- bluetooth/               (Guest's Bluetooth pairings)
|   |   +-- waydroid/                (Guest's Android apps/data)
|
+-- /mnt/shared --------------------> btrfs subvol=@shared
|   +-- tools/                       (CLI tools + scripts)
|   +-- configs/                     (Shared configurations)
|   +-- data/                        (cache, containers, vm, fonts, themes)
|   +-- waydroid/                    (Android base image)
|   +-- mnt/                         (External drive mount points)
|   +-- .swapfile                    (8GB swap)
|
+-- /var/lib/waydroid --------------> bind to /mnt/shared/waydroid
|
+-- /mnt/kubuntu -------------------> ext4 /dev/nvme0n1p5 (READ-ONLY)
|
+-- /boot --------------------------> ext4 /dev/nvme0n1p3
|
+-- /boot/efi ----------------------> vfat /dev/nvme0n1p1
```

---

## NixOS System Configuration

### What NixOS Provides

| Category | Packages/Services |
|----------|-------------------|
| **Display** | SDDM |
| **Sessions** | KDE Plasma, GNOME, Openbox, Waydroid, Kiosks |
| **Shell** | vim, fish |
| **System** | pciutils, usbutils, btrfs-progs, cryptsetup |
| **Openbox** | openbox, obconf, polybar, nitrogen, feh, rofi, dunst, picom, xterm |
| **Kiosk** | cage, wlr-randr |
| **Dialogs** | zenity, kdialog |
| **Fonts** | noto-fonts, noto-fonts-emoji, liberation_ttf, jetbrains-mono |

### What NixOS Does NOT Provide

All development tools come from @shared/tools/:

- CLI tools (curl, wget, git, htop, ripgrep, etc.)
- Compilers (gcc, clang, rustc, go)
- Languages (python, nodejs)
- DevOps (kubectl, terraform, docker-compose)
- Utility scripts (@shared/tools/scripts/)

---

## User Accounts

| User | UID | GID | Groups | Shell | Home |
|------|-----|-----|--------|-------|------|
| diego | 1000 | 100 (users) | wheel, networkmanager, video, audio, docker, podman, kvm, libvirtd | fish | @home-diego |
| guest | 1001 | 100 (users) | networkmanager, video, audio | fish | @home-guest |

### Fixed IDs (Cross-OS Compatible)

```nix
users.mutableUsers = false;  # Users only from config
users.users.diego.uid = 1000;
users.users.guest.uid = 1001;
users.groups.users.gid = 100;
users.groups.docker.gid = 998;
users.groups.podman.gid = 997;
users.groups.libvirtd.gid = 996;
users.groups.kvm.gid = 995;
```

---

## Per-User WiFi & Bluetooth

### Design

Each user owns their credentials - they travel with the home subvolume:

| Credential | Storage | Mechanism |
|------------|---------|-----------|
| **WiFi passwords** | `~/.local/share/keyrings/` | GNOME Keyring (auto-unlocked at login) |
| **Bluetooth pairings** | `~/.local/share/bluetooth/` | PAM session hook symlinks to /var/lib/bluetooth |

### How WiFi Works

NetworkManager stores WiFi passwords in the user's keyring (not system-connections):

```
~/.local/share/keyrings/
├── default.keyring      # Contains WiFi passwords
└── login.keyring        # Auto-unlocked at login
```

NixOS enables keyring integration:
```nix
services.gnome.gnome-keyring.enable = true;
security.pam.services.sddm.enableGnomeKeyring = true;
security.pam.services.sddm.enableKwallet = true;  # For KDE users
```

### How Bluetooth Works

At login, a PAM session hook symlinks the user's bluetooth directory:

```nix
# PAM session hook for per-user bluetooth
security.pam.services.sddm.text = lib.mkAfter ''
  session optional pam_exec.so /run/current-system/sw/bin/bash -c '
    mkdir -p $HOME/.local/share/bluetooth
    rm -rf /var/lib/bluetooth
    ln -sf $HOME/.local/share/bluetooth /var/lib/bluetooth
    chown -R $USER:users $HOME/.local/share/bluetooth 2>/dev/null || true
  '
'';
```

Structure after pairing a device:
```
~/.local/share/bluetooth/
└── <adapter-mac>/           # e.g., AA:BB:CC:DD:EE:FF
    └── <device-mac>/        # Paired device
        └── info             # Pairing keys
```

### Portability

When you move @home-diego to another NixOS:
- **WiFi**: First login will unlock keyring, NetworkManager reads passwords from it
- **Bluetooth**: PAM hook creates symlink, bluetoothd finds existing pairings

---

## Shared Tools System

### Tools Structure

```
/mnt/shared/tools/
├── base/
│   └── bin/           # curl, wget, git, htop, btop, ripgrep, fd, jq, tmux
├── dev/
│   └── bin/           # gcc, g++, clang, rustc, cargo, go, node, npm
├── data/
│   └── bin/           # python3, pip, jupyter, pandas
├── devops/
│   └── bin/           # kubectl, helm, terraform, ansible, docker-compose
└── scripts/           # Utility scripts (shared across all)
```

### Environment Variables

Set by NixOS:

```bash
# Shared caches (in data/)
CARGO_HOME=/mnt/shared/data/cache/cargo
GOPATH=/mnt/shared/data/cache/go
npm_config_cache=/mnt/shared/data/cache/npm
PIP_CACHE_DIR=/mnt/shared/data/cache/pip

# Tools directories in PATH
PATH=/mnt/shared/tools/base/bin:/mnt/shared/tools/dev/bin:/mnt/shared/tools/data/bin:/mnt/shared/tools/devops/bin:/mnt/shared/tools/scripts
```

### Populating Tools

```bash
# Using Nix profiles
nix profile install nixpkgs#{curl,wget,git,htop,ripgrep} --profile /mnt/shared/tools/base

# Or static binaries
curl -L https://...ripgrep...tar.gz | tar xz -C /mnt/shared/tools/base/bin/
```

### @shared Directory Overview

| Directory | Purpose |
|-----------|---------|
| `tools/` | CLI tools organized by category + scripts |
| `configs/` | Shared configurations (VPN, app configs) |
| `data/` | Persistent data: cache, containers, vm, fonts, themes |
| `waydroid/` | Android base image |
| `mnt/` | Mount points for external drives |

---

## Desktop Sessions (SDDM)

| Session | Type | Description |
|---------|------|-------------|
| **KDE Plasma** | Wayland | Full desktop (default) |
| **GNOME** | Wayland | Alternative full desktop |
| **Openbox** | X11 | Lightweight window manager |
| **Android** | Wayland | Full Waydroid UI via cage |
| **Tor Kiosk** | Wayland | Anonymous browsing kiosk |
| **Chrome Kiosk** | Wayland | Chromium fullscreen kiosk |
| **GNOME Kiosk** | Wayland | Locked down GNOME |

---

## Boot Flow

```
UEFI --> GRUB --> linux-surface kernel + initramfs
                        |
                        v
              +-------------------+
              |    INITRAMFS      |
              |-------------------|
              | 1. Load modules   |
              | 2. USB keyfile?   |
              | 3. LUKS decrypt   |
              | 4. Mount:         |
              |    / = tmpfs      |
              |    /nix = @nixos  |
              +-------------------+
                        |
                        v
              +-------------------+
              |     SYSTEMD       |
              |-------------------|
              | 5. Mount homes    |
              | 6. Mount @shared  |
              | 7. Create symlinks|
              | 8. Start services |
              +-------------------+
                        |
                        v
              +-------------------+
              |       SDDM        |
              |-------------------|
              | User: diego/guest |
              | Session: KDE/etc  |
              +-------------------+
```

---

## Key UUIDs

| Component | UUID |
|-----------|------|
| EFI Partition | `2CE0-6722` |
| /boot Partition | `0eaf7961-48c5-4b55-8a8f-04cd0b71de07` |
| LUKS Partition | `3c75c6db-4d7c-4570-81f1-02d168781aac` |
| USB Keyfile (Ventoy) | `223C-F3F8` |
| Kubuntu Root | `7e3626ac-ce13-4adc-84e2-1a843d7e2793` |
| Machine ID | `a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4` (hardcoded) |

---

## Build Commands

```bash
# Check configuration
nix flake check

# Build without switching
sudo nixos-rebuild build --flake .#surface

# Switch to new generation
sudo nixos-rebuild switch --flake .#surface

# Rollback
sudo nixos-rebuild switch --rollback

# List generations
sudo nix-env --list-generations -p /nix/var/nix/profiles/system
```

---

## Image Build Formats

### Primary Method: Raw EFI Image

The intended installation method is building a **raw-efi** disk image:

```bash
./build.sh build raw
```

This creates a bootable disk image that can be:
1. Written directly to USB: `dd if=nixos.raw of=/dev/sdX bs=4M`
2. Booted on Surface to run `nixos-install`
3. Or dd'd directly to the target NVMe partition

**Advantages:**
- Direct disk image, minimal overhead
- Can be resized after dd
- Fastest boot time

### Workaround: ISO Image (When Raw Fails)

**Problem Discovered (2026-01-08):**
The `raw-efi` format uses QEMU internally to populate the disk image. On systems
with limited RAM (<16GB), QEMU encounters I/O errors during the copy phase:

```
I/O error, dev vda, sector XXXXX op 0x1:(WRITE)
EXT4-fs warning: I/O error writing to inode...
ERROR: cptofs failed. diskSize might be too small for closure.
```

This happens even with sufficient disk size (32-48GB) because the issue is
QEMU memory/buffer exhaustion, not actual disk space.

**Workaround:**
Build an ISO image instead, which uses squashfs (no QEMU):

```bash
./build.sh build iso
```

**ISO Characteristics:**
- Uses squashfs compression (~4.4GB for full Plasma desktop)
- No QEMU involvement - more reliable on low-RAM systems
- Boot ISO → run installer → install to NVMe
- Slightly longer installation process (extra boot step)

### Format Comparison

| Format | Size | Method | RAM Needed | Use Case |
|--------|------|--------|------------|----------|
| **raw-efi** | ~20GB | QEMU + cptofs | 16GB+ | Direct dd to disk |
| **iso** | ~4.4GB | squashfs + xorriso | 8GB | Boot & install (workaround) |
| **qcow2** | ~15GB | QEMU | 8GB | VM testing |

### Recommendation

1. **First try**: `./build.sh build raw`
2. **If I/O errors**: `./build.sh build iso` (workaround)
3. **For VM testing**: `./build.sh build qcow` or `./build.sh build vm`

### Installation Flow

**With Raw Image:**
```
Build raw → dd to USB → Boot USB → dd to NVMe → Reboot → NixOS
```

**With ISO (Workaround):**
```
Build ISO → Copy to Ventoy USB → Boot ISO → nixos-install → Reboot → NixOS
```

Both result in the same installed system on the Surface's internal NVMe.

---

## Making Homes Portable

To move @home-diego to another NixOS system:

```bash
# On source system
sudo btrfs send /mnt/pool/@home-diego | zstd > home-diego.btrfs.zst

# On target system
zstd -d home-diego.btrfs.zst | sudo btrfs receive /mnt/pool/

# Update fstab/hardware-config to mount @home-diego
```

The home will work immediately because:
- UIDs are fixed (1000)
- No bind mounts to /persist needed
- All user data is self-contained
- **WiFi passwords** travel in `~/.local/share/keyrings/`
- **Bluetooth pairings** travel in `~/.local/share/bluetooth/`

### What Transfers With Home

| Component | Location | Portable? |
|-----------|----------|-----------|
| User configs | ~/.config/ | Yes |
| SSH keys | ~/.ssh/ | Yes |
| GPG keys | ~/.gnupg/ | Yes |
| WiFi passwords | ~/.local/share/keyrings/ | Yes |
| Bluetooth pairings | ~/.local/share/bluetooth/ | Yes |
| Android data | ~/.local/share/waydroid/ | Yes |
| Documents | ~/Documents/ | Yes |

---

## Known Issues & Fixes

### PAM Configuration Bug (Fixed 2026-01-08)

**Problem:**
SDDM graphical login would fail with "Permission denied" while SSH worked perfectly with the same credentials.

**Root Cause:**
The bluetooth portable pairings feature used `security.pam.services.login.text = lib.mkAfter` to add a session hook. However, in NixOS, setting `.text` **completely replaces** the PAM configuration instead of appending to it.

This resulted in `/etc/pam.d/login` only containing our bluetooth session hook:
```
session optional pam_exec.so /run/current-system/sw/bin/bash -c 'mkdir -p $HOME/.local/share/bluetooth...'
```

Missing the critical `auth`, `account`, and `password` entries required for password validation.

**Why SSH worked:**
SSH has its own complete PAM config at `/etc/pam.d/sshd` that wasn't affected.

**Why SDDM failed:**
SDDM's PAM config uses `auth substack login`, which references the broken `/etc/pam.d/login`.

**Fix:**
Removed the problematic PAM entries. The bluetooth symlink functionality needs to be reimplemented using:
- A systemd user service, OR
- udev rules, OR
- A login script

**Lesson Learned:**
Never use `security.pam.services.<name>.text` in NixOS - it replaces the entire PAM config. Use structured options like `.rules` instead, or find alternative mechanisms for login hooks.

### SDDM Virtual Keyboard (Surface Pro)

For touchscreen-only login on Surface Pro, the Qt6 virtual keyboard must be enabled:

```nix
services.displayManager.sddm = {
  settings.General.InputMethod = "qtvirtualkeyboard";
};
# IMPORTANT: Use Qt6 (kdePackages) for Plasma 6, NOT Qt5 (libsForQt5)
services.displayManager.sddm.extraPackages = with pkgs.kdePackages; [
  qtvirtualkeyboard
];
```

**Warning:** Using `libsForQt5.qtvirtualkeyboard` with Plasma 6 causes build failure:
```
Error: detected mismatched Qt dependencies:
    qtbase-5.15.15-dev
    qtbase-6.8.3
```

### VM Testing Requirements

When testing the ISO in virt-manager or QEMU:

1. **Disable Secure Boot** - NixOS bootloader is unsigned
2. Use OVMF without Secure Boot: `OVMF_CODE_4M.fd`
3. Create VM with: `--boot uefi,loader=/usr/share/OVMF/OVMF_CODE_4M.fd`

Secure Boot causes "Access Denied" on boot.

### Build Verification (2026-01-08)

**ISO Build Tested & Verified:**
- ✅ ISO builds successfully (~4.4GB)
- ✅ Uses cached kernel (no recompilation needed after initial build)
- ✅ Boots in VM with UEFI (OVMF_CODE_4M.fd)
- ✅ SDDM login works with `diego` / `1234567890`
- ✅ KDE Plasma 6 desktop loads correctly
- ✅ All applications accessible (Dolphin, Web, Waydroid, etc.)
- ✅ TTY login works (Ctrl+Alt+F2)
- ✅ SSH access works

**Test Command:**
```bash
# Build ISO
nix build .#iso

# Create VM (no Secure Boot)
virt-install --name nixos-test \
  --memory 4096 --vcpus 2 \
  --cdrom result/iso/*.iso \
  --disk size=20,bus=virtio \
  --osinfo nixos-unstable \
  --boot uefi,loader=/usr/share/OVMF/OVMF_CODE_4M.fd,cdrom,hd \
  --graphics spice
```
