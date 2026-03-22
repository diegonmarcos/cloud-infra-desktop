# Surface Pro 8 - Secure Workstation Architecture

> **Device**: Surface Pro 8 (Intel Tiger Lake, 8GB RAM, 256GB NVMe)
> **Primary OS**: NixOS (Full Impermanence)
> **Recovery**: Alpine Linux (unencrypted)
> **Security**: Kali Linux (unencrypted, pentesting)
> **Webcam**: Windows 11 Lite (unencrypted, driver compatibility)
> **Goal**: Android/ChromeOS-style isolation with declarative configuration

---

## Design Principles

| Principle | Implementation |
|-----------|----------------|
| **Declarative** | Everything defined in Nix, reproducible from scratch |
| **Immutable Core** | tmpfs root, /nix/store read-only, changes require rebuild |
| **Defense in Depth** | Multiple isolation layers (encryption, namespaces, VMs) |
| **Semantic Organization** | Clear separation: @system/, @user/, @shared/ |
| **Fail-Safe** | Unencrypted recovery OS always accessible |

---

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           SURFACE PRO 8 (256GB NVMe)                         │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                        NON-ENCRYPTED (~50GB)                           │  │
│  │                                                                        │  │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────────┐ ┌────────────────┐   │  │
│  │  │  EFI   │ │ /boot  │ │ ALPINE │ │   KALI     │ │  WINDOWS 11    │   │  │
│  │  │ 100MB  │ │  2GB   │ │  5GB   │ │   20GB     │ │    ~20GB       │   │  │
│  │  │        │ │        │ │        │ │            │ │                │   │  │
│  │  │rEFInd  │ │Kernels │ │Recovery│ │ Pentesting │ │ Webcam Driver  │   │  │
│  │  │Boot Mgr│ │+initrd │ │ Shell  │ │ Security   │ │ (Surface)      │   │  │
│  │  └────────┘ └────────┘ └────────┘ └────────────┘ └────────────────┘   │  │
│  │                                                                        │  │
│  │                    ALWAYS ACCESSIBLE (no password)                     │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                      LUKS ENCRYPTED (~180GB)                           │  │
│  │                                                                        │  │
│  │   Unlock: USB keyfile (automatic) OR password (fallback)              │  │
│  │                                                                        │  │
│  │  ┌──────────────────────────────────────────────────────────────────┐ │  │
│  │  │                         BTRFS POOL                               │ │  │
│  │  │                                                                  │ │  │
│  │  │   @system/nix        →  /nix           (Nix store, immutable)   │ │  │
│  │  │   @system/state      →  /var/lib       (system state)           │ │  │
│  │  │   @system/logs       →  /var/log       (system logs)            │ │  │
│  │  │                                                                  │ │  │
│  │  │   @user/home         →  /home/user     (user data)              │ │  │
│  │  │   @user/vault        →  ~/vault.tomb   (secrets, double-LUKS)   │ │  │
│  │  │                                                                  │ │  │
│  │  │   @shared/containers →  /var/lib/containers  (Podman)           │ │  │
│  │  │   @shared/flatpak    →  /var/lib/flatpak     (Flatpak apps)     │ │  │
│  │  │   @shared/microvm    →  /var/lib/microvms    (microvm.nix)      │ │  │
│  │  │   @shared/waydroid   →  /var/lib/waydroid    (Android)          │ │  │
│  │  │   @shared/swap       →  /.swapfile           (8GB swap)         │ │  │
│  │  │                                                                  │ │  │
│  │  └──────────────────────────────────────────────────────────────────┘ │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                         USB KEY (Ventoy)                               │  │
│  │                                                                        │  │
│  │   VTOYEFI/.luks/surface.key    → Unlocks LUKS at boot                 │  │
│  │   VTOYEFI/.vault/vault.key     → Unlocks vault (optional)             │  │
│  │   Ventoy partition             → ISOs, tools, portable apps           │  │
│  │                                                                        │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Security Zones

| Zone | Name | Encryption | Access | Purpose |
|------|------|------------|--------|---------|
| **0** | Recovery | None | Always | Emergency repair, unlock LUKS |
| **1a** | Webcam | None | Always | Surface webcam driver (Windows) |
| **1b** | Security | None | Always | Pentesting, security auditing (Kali) |
| **2** | System | LUKS | Boot unlock | NixOS host, trusted tools |
| **3** | User | LUKS + Vault | Boot + manual | Personal data, secrets |
| **4** | Untrusted | LUKS | Boot unlock | microvm.nix VMs, isolated workloads |

---

## Isolation Layers

```
                    TRUST LEVEL
    100%          80%           60%           40%            0%
     │             │             │             │              │
     ▼             ▼             ▼             ▼              ▼
┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐   ┌──────────────┐
│   NIX   │  │DISTROBOX│  │ FLATPAK │  │ PODMAN  │   │     KATA     │
│ NATIVE  │  │  (DEV)  │  │  (GUI)  │  │(SERVICE)│   │  (UNTRUSTED) │
│         │  │         │  │         │  │         │   │              │
│  git    │  │  Arch   │  │ Firefox │  │  nginx  │   │ ┌──────────┐ │
│  vim    │  │  Node   │  │ VSCode  │  │Postgres │   │ │  Guest   │ │
│  htop   │  │ Python  │  │ Discord │  │  Redis  │   │ │  Kernel  │ │
│         │  │         │  │         │  │         │   │ └──────────┘ │
└─────────┘  └─────────┘  └─────────┘  └─────────┘   └──────────────┘
     │             │             │             │              │
  KERNEL:       KERNEL:       KERNEL:       KERNEL:       KERNEL:
  Shared        Shared        Shared        Shared        ISOLATED
     │             │             │             │              │
  FILES:        FILES:        FILES:        FILES:        FILES:
  Full          $HOME         Portal        Volume        Isolated
  Access        Shared        Only          Only
```

### Sandbox Comparison

| Type | Kernel | Filesystem | Network | Overhead | Use For |
|------|--------|------------|---------|----------|---------|
| **Nix Native** | Shared | Full | Full | 0% | CLI tools, system utils |
| **Distrobox** | Shared | $HOME shared | Full | ~1% | Compilers, dev envs |
| **Flatpak** | Shared | Portal only | Restricted | ~2% | Browsers, chat, GUI |
| **Podman** | Shared | Volume only | Isolated | ~2% | Services, databases |
| **microvm.nix** | **Isolated** | **Isolated** | Isolated | ~5-10% | Untrusted, CI/CD |

---

## OS Components

### 1. NixOS (Primary)

- **Root**: tmpfs (2GB RAM) - wiped every boot
- **Configuration**: Declarative Nix flakes
- **Persistence**: Impermanence module binds @system/state and @user/home
- **Desktop Sessions** (via SDDM):
  - KDE Plasma (Wayland) - Full desktop, default
  - GNOME (Wayland) - ChromeOS-like
  - Waydroid (Wayland) - Android fullscreen
  - Openbox (X11) - Lightweight
  - Brave Kiosk (Wayland) - Browser-only
- **Containers**: Docker, Podman (rootless), Distrobox, Flatpak, microvm.nix

### 2. Alpine Recovery (Zone 0)

- **Purpose**: Emergency access when NixOS fails or LUKS needs repair
- **Size**: ~5GB ext4 partition
- **Tools**: cryptsetup, btrfs-progs, fsck, networking, SSH
- **Access**: Always bootable, no encryption

### 3. Windows 11 Lite (Zone 1)

- **Purpose**: Surface Pro webcam driver compatibility
- **Size**: ~20GB NTFS partition
- **Optimization**: Minimal install, no bloatware, webcam drivers only
- **Use Case**: Virtual webcam piping to NixOS via network

---

## Boot Flow

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                              BOOT SEQUENCE                                    │
└───────────────────────────────────────────────────────────────────────────────┘

   POWER ON
       │
       ▼
┌─────────────┐
│   UEFI      │
│   Firmware  │
└──────┬──────┘
       │
       ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   rEFInd    │────▶│   NixOS     │     │   Alpine    │     │  Windows    │
│   (EFI)     │     │  (Default)  │     │  Recovery   │     │   Webcam    │
└─────────────┘     └──────┬──────┘     └─────────────┘     └─────────────┘
                           │
                           ▼
                    ┌─────────────┐
                    │  initramfs  │
                    │  (NixOS)    │
                    └──────┬──────┘
                           │
              ┌────────────┴────────────┐
              │                         │
              ▼                         ▼
       ┌─────────────┐          ┌─────────────┐
       │  USB KEY    │          │  PASSWORD   │
       │  FOUND?     │          │  PROMPT     │
       └──────┬──────┘          └──────┬──────┘
              │ YES                    │
              └────────────┬───────────┘
                           │
                           ▼
                    ┌─────────────┐
                    │ LUKS UNLOCK │
                    │ /dev/mapper │
                    │    /pool    │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │  BTRFS      │
                    │  Mount      │
                    │  Subvolumes │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │  tmpfs /    │
                    │  (2GB RAM)  │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │ Impermanence│
                    │ Bind Mounts │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │   SDDM      │
                    │  (Login)    │
                    └─────────────┘
```

---

## Repository Structure

```
/home/diego/mnt_git/unix/
│
├── 0_spec/                          # Architecture & specifications
│   ├── ARCHITECTURE.md              # This document (main overview)
│   ├── DISK_LAYOUT.md               # Partition and subvolume details
│   ├── ISOLATION_LAYERS.md          # Security zones and sandboxing
│   ├── PERSONAL_SPACE.md            # User space organization
│   ├── ROADMAP.md                   # Implementation checklist
│   ├── TOOLS.md                     # Package lists
│   └── z_dotfiles_src/              # Dotfile templates
│
├── a_nixos_host/                    # NixOS configuration
│   ├── 0_spec/                      # NixOS-specific docs
│   ├── flake.nix                    # Flake entry point
│   ├── flake.lock                   # Dependency lock
│   ├── configuration.nix            # Main config
│   ├── hardware-configuration.nix   # Hardware + LUKS + mounts
│   └── build.sh                     # Build/deploy script
│
├── a_alpine_fallback/               # Alpine recovery OS
│   └── build.sh                     # Build recovery partition
│
├── a_win11_webcam/                  # Windows 11 webcam OS
│   └── 7_keys/                      # License keys
│
├── b_apps/                          # Application configurations
│   ├── 0.spec/                      # App lists
│   ├── src_container/               # Container definitions
│   ├── src_flatpak/                 # Flatpak overrides
│   └── src_host/                    # Host package lists
│
└── b_mnt/                           # Mount configurations
    ├── mount.sh                     # Mount script
    └── mount.json                   # Mount definitions
```

---

## Key UUIDs

| Component | UUID | Type |
|-----------|------|------|
| EFI Partition | `2CE0-6722` | FAT32 |
| /boot Partition | `0eaf7961-48c5-4b55-8a8f-04cd0b71de07` | ext4 |
| LUKS Partition | `3c75c6db-4d7c-4570-81f1-02d168781aac` | LUKS2 |
| USB Keyfile | `223C-F3F8` | FAT32 (Ventoy) |

---

## Default Credentials

| Component | Value | Notes |
|-----------|-------|-------|
| LUKS Password | `1234567890` | **CHANGE AFTER SETUP** |
| User | `user` | UID 1000 |
| User Password | `1234567890` | **CHANGE AFTER SETUP** |
| Sudo | `NOPASSWD: ALL` | For wheel group |
| SSH | Password auth enabled | Port 22 open |

---

## Related Documentation

| Document | Purpose |
|----------|---------|
| [DISK_LAYOUT.md](./DISK_LAYOUT.md) | Detailed partition and subvolume spec |
| [ISOLATION_LAYERS.md](./ISOLATION_LAYERS.md) | Security zones and sandbox details |
| [PERSONAL_SPACE.md](./PERSONAL_SPACE.md) | User space organization |
| [ROADMAP.md](./ROADMAP.md) | Implementation checklist |
| [a_nixos_host/0_spec/runbook.md](../a_nixos_host/0_spec/runbook.md) | Step-by-step procedures |
