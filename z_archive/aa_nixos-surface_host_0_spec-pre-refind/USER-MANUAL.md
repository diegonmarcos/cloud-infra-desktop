# NixOS Surface Pro 8 - User Manual

> Quick reference for daily use. For technical details, see `ARCHITECTURE.md`.

---

## Quick Start

### Login
- **User:** `diego` or `guest`
- **Password:** `1234567890`
- **Touchscreen:** Virtual keyboard available at SDDM login

### Sessions Available (SDDM)
| Session | Description |
|---------|-------------|
| **Plasma** | KDE desktop (default) |
| **GNOME** | Alternative desktop |
| **Openbox** | Lightweight X11 |
| **Android** | Full Waydroid UI |
| **Tor Kiosk** | Anonymous browsing |
| **Chrome Kiosk** | Fullscreen Chromium |

---

## Essential Commands

### System Management
```bash
# Rebuild NixOS (apply config changes)
sudo nixos-rebuild switch --flake /nix/specs#surface

# Rollback to previous generation
sudo nixos-rebuild switch --rollback

# List system generations
sudo nix-env --list-generations -p /nix/var/nix/profiles/system

# Garbage collect old generations
sudo nix-collect-garbage -d
```

### Package Management
```bash
# Search packages
nix search nixpkgs firefox

# Install via Flatpak (recommended for GUI apps)
flatpak search firefox
flatpak install flathub org.mozilla.firefox

# Install via nix profile (user-level)
nix profile install nixpkgs#htop

# Temporary shell with package
nix shell nixpkgs#python3
```

### Useful Shortcuts
```bash
# Claude Code
bash ~/user/claude.sh

# Quick file manager
dolphin .

# Terminal
konsole
```

---

## Storage Layout

```
/                     tmpfs (2GB) - WIPED EVERY REBOOT
/nix                  Nix store (persistent)
/home/diego           Your home (persistent btrfs)
/home/guest           Guest home (persistent btrfs)
/mnt/shared           Shared storage (cross-OS)
/mnt/btrfs-root       All subvolumes visible
/mnt/kubuntu          Kubuntu root (read-only)
```

### Important Paths
| Path | Purpose |
|------|---------|
| `/nix/specs/` | NixOS configuration files |
| `/mnt/shared/tools/` | Shared CLI tools |
| `/mnt/shared/data/` | Caches, containers, VMs |
| `~/.local/share/keyrings/` | Your WiFi passwords |

---

## WiFi & Bluetooth

### WiFi
- **First connection:** Enter password normally
- **Storage:** Saved in your keyring (travels with your home)
- **Per-user:** Each user has their own saved networks

### Bluetooth
- **Pair once:** Works for all users
- **Storage:** `/mnt/shared/bluetooth/` (cross-OS)
- **Note:** Pairings stay with machine, not user

---

## What Persists vs Resets

### Persists (survives reboot)
- Your home directory (`/home/diego/`)
- Nix store (`/nix/`)
- Shared storage (`/mnt/shared/`)
- WiFi passwords (in your keyring)
- Bluetooth pairings (in @shared)
- Flatpak apps and data

### Resets (wiped on reboot)
- Root filesystem (`/`)
- `/etc/` (regenerated from config)
- `/var/` (ephemeral)
- SSH host keys (regenerate each boot)
- Temporary files

---

## Installing Software

### Option 1: Flatpak (Recommended for GUI apps)
```bash
flatpak install flathub com.spotify.Client
flatpak install flathub com.discordapp.Discord
flatpak install flathub com.valvesoftware.Steam
```

### Option 2: Nix Profile (User-level CLI tools)
```bash
nix profile install nixpkgs#ripgrep
nix profile install nixpkgs#fd
nix profile list
nix profile remove ripgrep
```

### Option 3: System Packages (Requires rebuild)
Edit `/nix/specs/configuration.nix`, add to `environment.systemPackages`, then:
```bash
sudo nixos-rebuild switch --flake /nix/specs#surface
```

### Option 4: Temporary Shell
```bash
nix shell nixpkgs#python3 nixpkgs#nodejs
# Tools available only in this shell
```

---

## Waydroid (Android)

### Start Android Session
1. Select "Android (Waydroid)" at SDDM login, OR
2. From desktop: `waydroid show-full-ui`

### Initialize (first time only)
```bash
sudo waydroid init
```

### Install APK
```bash
waydroid app install ~/Downloads/app.apk
```

---

## Containers (Docker/Podman)

```bash
# Docker
docker run hello-world
docker ps

# Podman (rootless)
podman run hello-world
podman ps
```

Data stored in `/mnt/shared/data/containers/`

---

## Rescue Mode

Boot into rescue mode from GRUB menu: **"NixOS - Rescue"**

### What You Get
- Root terminal (auto-login)
- WiFi available (via `nmtui`)
- No desktop (text mode only)
- Recovery tools included

### Common Tasks in Rescue Mode

```bash
# Connect to WiFi
nmtui
# Or directly:
nmcli device wifi connect "SSID" password "PASSWORD"

# Check disk status
lsblk
btrfs filesystem show
cryptsetup status pool

# Rebuild system
nixos-rebuild switch --flake /nix/specs#surface

# Rollback to previous generation
nixos-rebuild switch --rollback

# View logs
journalctl -xb

# Check filesystem
btrfs check --readonly /dev/mapper/pool

# Exit rescue mode
reboot
```

### Available Tools
| Category | Tools |
|----------|-------|
| Filesystem | btrfs-progs, e2fsprogs, cryptsetup, parted, gptfdisk |
| Network | nmtui, nmcli, iw, wpa_supplicant |
| Recovery | testdisk, ddrescue, rsync |
| System | htop, lsof, strace, smartmontools |

---

## Troubleshooting

### Can't delete files in Dolphin
Fixed by tmpfiles rules. If issue persists:
```bash
mkdir -p ~/.local/share/Trash/{files,info}
```

### WiFi not connecting
Your keyring may be locked. Log out and back in, or:
```bash
gnome-keyring-daemon --unlock
```

### Script fails with "bad interpreter"
All standard scripts should work (`/bin/bash` exists). If custom script fails:
```bash
# Check shebang
head -1 script.sh
# Should be #!/bin/bash or #!/usr/bin/env bash
```

### Bluetooth device not pairing
```bash
bluetoothctl
# Then: scan on, pair XX:XX:XX:XX, connect XX:XX:XX:XX
```

### System won't boot
1. At GRUB, select previous generation
2. Boot into Kubuntu and fix config
3. Rebuild: `./build.sh build iso`

---

## Files Reference

| File | Purpose |
|------|---------|
| `/nix/specs/flake.nix` | Flake definition (inputs, outputs) |
| `/nix/specs/configuration.nix` | Main NixOS configuration |
| `/nix/specs/hardware-configuration.nix` | Hardware-specific settings |
| `/nix/specs/README.md` | This manual |
| `/nix/specs/ARCHITECTURE.md` | Technical documentation |

---

## Support

- **Config location:** `/nix/specs/` or `/mnt/kubuntu/home/diego/mnt_git/unix/a_nixos_host/`
- **Issues log:** Check `ISSUES-STATUS.md`
- **NixOS manual:** `man configuration.nix` or https://nixos.org/manual/nixos/stable/

---

*System: NixOS 24.11 | Kernel: linux-surface | Device: Surface Pro 8*
