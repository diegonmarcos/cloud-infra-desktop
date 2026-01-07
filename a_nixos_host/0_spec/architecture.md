# NixOS Host Architecture

> **Device**: Surface Pro 8 (Intel Tiger Lake, 8GB RAM, 256GB NVMe)
> **OS**: NixOS 24.11 - Minimal + User Agnostic
> **Boot**: GRUB (LUKS2 + USB keyfile unlock)
> **Status**: Dual-boot with Kubuntu
> **Philosophy**: Minimal NixOS + Shared Tools + Detachable Homes

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
