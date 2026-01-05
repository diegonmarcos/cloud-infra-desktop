# NixOS Bifrost Architecture

## Overview

NixOS companion to Kubuntu - a declarative, reproducible operating system for the Surface Pro 8 dual-boot setup with full impermanence (tmpfs root).

```
┌─────────────────────────────────────────────────────────────────────┐
│                        SURFACE PRO 8                                │
├─────────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │    GRUB      │  │   Kubuntu    │  │    NixOS     │              │
│  │  Bootloader  │──│   (Host)     │──│   Bifrost    │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
│         │                 │                 │                       │
│         ▼                 ▼                 ▼                       │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    LUKS2 Encrypted Pool                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │  │
│  │  │ @root-nixos │  │ @home-nixos │  │  @shared    │          │  │
│  │  │  /nix       │  │   /home     │  │  (common)   │          │  │
│  │  │  /persist   │  │             │  │             │          │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘          │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## Current Installation Status

| Component | Status | Details |
|-----------|--------|---------|
| **NixOS Version** | 24.11.20250630 | Kernel 6.12.19 |
| **Boot** | GRUB entry | Shared with Kubuntu |
| **Root** | tmpfs (2GB) | Wiped on reboot |
| **Nix Store** | @root-nixos/nix | 14,255 store paths |
| **Persist** | @root-nixos/persist | SSH keys, machine-id |
| **Desktop** | KDE Plasma 6 + GNOME + Openbox | SDDM display manager |

## Comparison: Kubuntu vs NixOS

| Feature | Kubuntu (Host) | NixOS Bifrost |
|---------|----------------|---------------|
| **Base** | Ubuntu 24.04 | NixOS 24.11 |
| **Updates** | apt | nixos-rebuild |
| **Config** | /etc files | Nix expressions |
| **Rollback** | Timeshift | generations |
| **Packages** | apt + snap | nixpkgs + flakes |
| **Desktop** | KDE Plasma | KDE + GNOME + Openbox |
| **Root** | ext4 | tmpfs (impermanence) |

## Directory Structure

```
/home/diego/mnt_git/unix/a_nixos_host/     # Git repo (scripts & config)
├── 0_spec/
│   ├── architecture.md                    # This file
│   └── runbook.md                         # Step-by-step procedures
├── flake.nix                              # Flake definition
├── configuration.nix                      # NixOS configuration
└── hardware-configuration.nix             # Hardware & filesystem config

/mnt/nixos/result/                         # Build output symlink
└── nixos.img                              # Raw disk image (27.6 GB)
```

## Disk Layout

### Partitions

| Partition | UUID | Type | Mount | Size |
|-----------|------|------|-------|------|
| nvme0n1p1 | 2CE0-6722 | vfat | /boot/efi | 512M |
| nvme0n1p2 | 0eaf7961-... | ext4 | /boot | 1G |
| nvme0n1p3 | 7e3626ac-... | ext4 | / (Kubuntu) | ~50G |
| nvme0n1p4 | 3c75c6db-... | LUKS2 | /dev/mapper/pool | ~117G |

### BTRFS Subvolumes (on /dev/mapper/pool)

```
/dev/mapper/pool (117GB, btrfs, zstd compression)
├── @root-kinoite        # Reserved for Kinoite
├── @root-nixos          # NixOS root container
│   ├── nix/             # Nested: /nix store (21GB)
│   └── persist/         # Nested: persistent state
├── @home-kinoite        # Reserved for Kinoite
├── @home-nixos          # NixOS /home
├── @shared              # Shared between OSes
│   └── nix/             # Build-time nix store
└── @android             # Waydroid storage
```

### NixOS Filesystem Mounts

| Mount Point | Device | Type | Options |
|-------------|--------|------|---------|
| `/` | none | tmpfs | size=2G, mode=755 |
| `/nix` | pool | btrfs | subvol=@root-nixos/nix |
| `/persist` | pool | btrfs | subvol=@root-nixos/persist |
| `/home` | pool | btrfs | subvol=@home-nixos |
| `/mnt/shared` | pool | btrfs | subvol=@shared |
| `/boot` | nvme0n1p2 | ext4 | - |
| `/boot/efi` | nvme0n1p1 | vfat | umask=0077 |
| `/var/lib/waydroid` | pool | btrfs | subvol=@android |

## Boot Configuration

### GRUB Entry

Location: `/etc/grub.d/40_nixos` (on Kubuntu)

```
menuentry "NixOS" --class nixos --class gnu-linux --class os {
    search --no-floppy --fs-uuid --set=root 0eaf7961-48c5-4b55-8a8f-04cd0b71de07
    linux /nixos/vmlinuz init=/nix/store/pl0y29z2i540q27fh63q1m9kw21jwgvn-nixos-system-surface-nixos-24.11.20250630.50ab793/init loglevel=4
    initrd /nixos/initrd
}
```

### Boot Files

```
/boot/
├── nixos/
│   ├── vmlinuz          # NixOS kernel (6.12.19)
│   └── initrd           # NixOS initramfs
├── grub/
│   └── grub.cfg         # GRUB config (includes NixOS)
└── efi/
    └── EFI/
        ├── GRUB/        # Kubuntu's GRUB
        ├── ubuntu/      # Ubuntu boot
        └── Microsoft/   # Windows boot
```

## Impermanence Model

NixOS runs with tmpfs root - everything is wiped on reboot except:

### Persisted Directories (`/persist`)

```
/persist/
├── var/
│   ├── lib/
│   │   ├── nixos/           # NixOS state
│   │   ├── systemd/         # systemd state
│   │   ├── bluetooth/       # Bluetooth pairings
│   │   ├── NetworkManager/  # Network connections
│   │   ├── docker/          # Docker data
│   │   └── containers/      # Podman data
│   └── log/                 # System logs
├── etc/
│   ├── machine-id           # Machine identifier
│   ├── ssh/                 # SSH host keys
│   └── NetworkManager/
│       └── system-connections/  # WiFi passwords
└── home/
    └── user/
        ├── .config/
        ├── .local/
        ├── .cache/
        ├── .ssh/
        ├── .gnupg/
        ├── Documents/
        ├── Downloads/
        └── Projects/
```

## Build Pipeline

```
┌─────────────────────────────────────────────────────────────────┐
│                    BUILD PIPELINE (from Kubuntu)                 │
└─────────────────────────────────────────────────────────────────┘

 1. Setup                  2. Build                  3. Extract
┌───────────────┐      ┌───────────────┐      ┌───────────────┐
│ Mount pool    │      │ nix build     │      │ Copy closure  │
│ Bind /nix to  │ ───▶ │ .#raw         │ ───▶ │ to @root-nixos│
│ @shared       │      │               │      │ /nix/store    │
└───────────────┘      └───────────────┘      └───────────────┘
                                                      │
                              ┌────────────────────────┤
                              │                        │
                              ▼                        ▼
                       ┌───────────┐            ┌───────────┐
                       │ Copy      │            │ Add GRUB  │
                       │ kernel +  │            │ entry     │
                       │ initrd    │            │           │
                       └───────────┘            └───────────┘
                              │
                              ▼
 4. Boot
┌───────────────┐
│ Reboot        │
│ Select NixOS  │
│ Enter LUKS pw │
└───────────────┘
```

## Package Sources

1. **nixpkgs** - Primary package source (100k+ packages)
2. **nixos-hardware** - Surface Pro 8 specific support
3. **impermanence** - Persistent state management
4. **nixos-generators** - Image building
5. **Flatpak** - GUI apps not in nixpkgs

## System Resources

| Resource | Kubuntu | NixOS |
|----------|---------|-------|
| **Swap** | 8GB (`/swapfile`) | 8GB (`/mnt/shared/.swapfile`) |
| **CPU Governor** | performance | performance (no cap) |
| **RAM** | 8GB total | 8GB total |

## Security Stack

| Layer | Implementation |
|-------|----------------|
| Disk | LUKS2 encrypted pool |
| Boot | GRUB with LUKS unlock |
| Firewall | nftables (port 22 open) |
| Updates | Atomic generations |
| SSH | Key-based + password |

## Desktop Sessions

| Session | Type | Description |
|---------|------|-------------|
| **Plasma (KDE)** | Wayland | Full desktop (default) |
| **GNOME** | Wayland | Alternative desktop |
| **Openbox** | X11 | Lightweight WM |
| **Android (Waydroid)** | Wayland | Full Android UI |
| **Tor Kiosk** | Wayland | Tor Browser kiosk |
| **Chrome Kiosk** | Wayland | Chromium kiosk |

## Container Setup

| Engine | Storage Location | Network |
|--------|------------------|---------|
| Docker | /mnt/shared/containers/docker | bridge |
| Podman | /mnt/shared/containers/podman | rootless |

Both use btrfs storage driver on the shared subvolume.

## Related Resources

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [nixos-generators](https://github.com/nix-community/nixos-generators)
- [Impermanence](https://github.com/nix-community/impermanence)
- [nixos-hardware Surface](https://github.com/NixOS/nixos-hardware/tree/master/microsoft/surface)
