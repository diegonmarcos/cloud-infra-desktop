# UNIX - Secure Workstation & Fallback Infrastructure

> **Device**: Surface Pro 8 (Intel Tiger Lake)
> **Goal**: A high-security, declarative, and immutable UNIX environment with multiple layers of fail-safe recovery.

---

## Table of Contents

### A) Documentation Overview
- [A.1 Security Zones](#a1-security-zones)
- [A.2 Operating Systems](#a2-operating-systems)
- [A.3 Nix Flakes (User Environment)](#a3-nix-flakes-user-environment)
- [A.4 Applications & Containers](#a4-applications--containers)
- [A.5 Quick Start](#a5-quick-start)
- [A.6 Filesystem Layout](#a6-filesystem-layout)
- [A.7 Surface Hardware Notes](#a7-surface-hardware-notes)

### B) Architectural Design
- [B.1 Repository Structure](#b1-repository-structure)
- [B.2 Build System](#b2-build-system)
- [B.3 NixOS Host Configuration](#b3-nixos-host-configuration)
- [B.4 Home Manager Profiles](#b4-home-manager-profiles)
- [B.5 Isolation Layers](#b5-isolation-layers)
- [B.6 MCP Server](#b6-mcp-server)
- [B.7 Disk Partitioning](#b7-disk-partitioning)

---

## A) Documentation Overview

### A.1 Security Zones

| Zone | System | Encryption | Purpose |
| :--- | :--- | :--- | :--- |
| **0** | **Alpine Recovery** | None | Emergency repair, LUKS rescue |
| **1a** | **Windows 11 Lite** | None | Hardware compatibility (Surface Webcam) |
| **1b** | **Kali Security** | None | Security auditing & pentesting |
| **2** | **NixOS (Host)** | LUKS2 | Primary Workstation (Impermanence) |
| **3** | **User Space** | LUKS + Vault | Personal data & secret management |
| **4** | **Untrusted** | LUKS | Isolated workloads via `microvm.nix` |

### A.2 Operating Systems

| OS | Folder | Purpose |
|----|--------|---------|
| **NixOS 24.11** | `aa_nixos-surface_host/` | Primary workstation. Immutable root (tmpfs), impermanence, KDE Plasma 6 |
| **Arch Linux** | `ab_arch-surface_fallback_desk/` | Desktop fallback with Surface hardware support |
| **Kali Linux** | `ab_kali_security/` | Security auditing, network forensics (debootstrap) |
| **Windows 11 Lite** | `ac_win11_webcam/` | Surface webcam driver support |
| **Ventoy USB** | `ad_ventoy_fallback_usb/` | Multi-OS recovery: Debian, Arch, Alpine, NixOS Slim |
| **Android/Mobile** | `ae_mobile_image/` | BlissOS QEMU VM, Samsung app extraction |

### A.3 Nix Flakes (User Environment)

#### Desktop — [`ba_flakes_desktop/`](./ba_flakes_desktop)

Standalone Home Manager that works on **any Linux distro**. Manages packages, dotfiles, desktop environments.

**Host Configs**: `surface-plasma` (all profiles + Plasma 6), `surface-gnome`, `server`, `cli`, `minimal`.

#### Termux — [`bb_flakes_termux/`](./bb_flakes_termux)

Nix Home Manager for Android/Termux. Mobile development environment with Claude Code, MCP servers, and full CLI tooling.

### A.4 Applications & Containers

| Directory | Purpose |
|-----------|---------|
| `ca_container_cli/` | CLI tools container (Podman/Docker) |
| `cb_container_gui/` | GUI apps container (Podman/Docker) |
| `de_claude-sandbox/` | Claude AI sandbox (Nix + AppImage) |
| `bc_unix-mcp-api/` | Unix MCP server (system introspection) |

### A.5 Quick Start

```bash
# Rebuild NixOS system
~/git/unix/aa_nixos-surface_host/build.sh       # Interactive TUI

# Rebuild Home Manager (desktop)
~/git/unix/ba_flakes_desktop/build.sh switch surface

# Rebuild Home Manager (Termux/mobile)
~/git/unix/bb_flakes_termux/build.sh switch
```

### A.6 Filesystem Layout

```
/                       # tmpfs (ephemeral, wiped on reboot)
├── nix/                # @system/nix subvolume (persistent)
├── home/diego/         # @user/home-diego subvolume (persistent)
├── home/guest/         # @user/home-guest subvolume (persistent)
├── mnt/
│   ├── shared/         # @shared subvolume (cross-OS data)
│   ├── btrfs-root/     # Pool root (all subvolumes visible)
│   └── kubuntu/        # Kubuntu ext4 partition (ro)
└── boot/efi/           # EFI system partition
```

- **LUKS2**: Full disk encryption, USB keyfile + password fallback
- **BTRFS**: zstd compression, noatime
- **zRAM swap**: 50% of RAM (4GB compressed)
- **Docker/Podman data**: `/mnt/shared/data/containers/`

### A.7 Surface Hardware Notes

- **initrd modules**: `surface_aggregator`, `surface_hid` loaded early for Type Cover keyboard
- **No Intel ISH**: Surface Pro 8 uses SAM (Surface Aggregator Module)
- **Wayland**: Default (Plasma 6), X11 available for Openbox
- **Touchscreen/Pen**: via `nixos-hardware` Surface module
- **Kernel**: linux-surface (mainline 6.15+ with Surface patches)
- **Dual-boot**: Kubuntu (ext4 partition, shared boot)

---

## B) Architectural Design

### B.1 Repository Structure

```
unix/
├── 0_spec/                            Specifications & design docs
│   ├── ARCHITECTURE.md                System-wide design
│   ├── DISK_LAYOUT.md                 Partition & subvolume map
│   ├── ISOLATION_LAYERS.md            Sandbox breakdown
│   └── TOOLS.md                       Curated package lists
│
├── aa_nixos-surface_host/             NixOS host configuration
├── ab_arch-surface_fallback_desk/     Arch Linux fallback
├── ab_kali_security/                  Kali security zone
├── ac_win11_webcam/                   Windows hardware fallback
├── ad_ventoy_fallback_usb/            Multi-OS USB recovery
├── ae_mobile_image/                   Android image management
│
├── ba_flakes_desktop/                 Home Manager (desktop)
├── bb_flakes_termux/                  Home Manager (Termux)
├── bc_unix-mcp-api/                   Unix MCP server
│
├── ca_container_cli/                  CLI container (Podman)
├── cb_container_gui/                  GUI container (Podman)
├── de_claude-sandbox/                 Claude AI sandbox
│
└── z_archive/                         Archived configs
```

### B.2 Build System

Every major project uses `build.sh` (engine) + `build.json` (config) at project root.

| Project | Engine | Purpose |
|---------|--------|---------|
| `aa_nixos-surface_host/build.sh` | NixOS installer | Create raw EFI / ISO images for Surface |
| `ba_flakes_desktop/build.sh` | Home Manager | Switch/build/update desktop environment |
| `bb_flakes_termux/build.sh` | nix-on-droid | Switch/build/update Termux environment |
| `bc_unix-mcp-api/build.sh` | Node.js | Build MCP server |
| `ca_container_cli/build.sh` | Podman | Build CLI container |
| `cb_container_gui/build.sh` | Podman | Build GUI container |

### B.3 NixOS Host Configuration

- **Flake**: `aa_nixos-surface_host/src/flake.nix`
- **Impermanence**: Root is `tmpfs`, wiped on reboot. Persistent data via BTRFS subvolumes.
- **Multi-user**: `diego` (UID 1000), `guest` (UID 1001)
- **Desktop**: KDE Plasma 6 (Wayland), GNOME, Openbox
- **Shell**: Fish (default), Zsh, Bash

### B.4 Home Manager Profiles

Desktop flake provides modular, composable profiles:

| Profile | Packages |
|---------|----------|
| `shell-core` | zsh, starship, fzf, ripgrep, fd, bat, eza |
| `dev-languages` | Node, Python, Rust, Go runtimes |
| `build-debug` | cmake, gcc, gdb, valgrind, strace |
| `containers-cloud` | podman, kubectl, helm, gcloud, aws, oci-cli |
| `security-network` | nmap, wireshark, burpsuite, openssl |
| `data-science` | jupyter, pandas, numpy, R |
| `productivity` | obsidian, zotero, libreoffice |
| `media-graphics` | gimp, inkscape, ffmpeg, imagemagick |

### B.5 Isolation Layers

| Layer | Technology | Trust Level | Use Case |
|-------|-----------|-------------|----------|
| 1 | Nix Native | Trusted | CLI & system utilities |
| 2 | Distrobox | Semi-trusted | Development environments (Arch, Ubuntu) |
| 3 | Flatpak | Sandboxed | GUI applications |
| 4 | Podman | Rootless | Containerized services |
| 5 | MicroVM | Fully isolated | Untrusted workloads (separate kernel) |

### B.6 MCP Server

`bc_unix-mcp-api/` — stdio MCP server for system introspection.

Provides tools for shell management, Nix operations, Git sync, mesh networking, dev servers, and system information. Used by Claude Code for local system context.

### B.7 Disk Partitioning

| Partition | Size | FS | Mount | Purpose |
|-----------|------|-----|-------|---------|
| EFI | 512M | FAT32 | `/boot/efi` | Bootloader (systemd-boot) |
| NixOS | ~200G | BTRFS (LUKS) | `/` | System + user data |
| Kubuntu | ~50G | ext4 | `/mnt/kubuntu` (ro) | Dual-boot fallback |
| Kali | ~20G | ext4 | — | Security zone |
| Recovery | ~2G | ext4 | — | Alpine rescue |

BTRFS subvolumes: `@system/nix`, `@system/state`, `@user/home-diego`, `@user/home-guest`, `@shared`.

---

**Quick Links**: [Architecture](./0_spec/ARCHITECTURE.md) | [Disk Layout](./0_spec/DISK_LAYOUT.md) | [Isolation Layers](./0_spec/ISOLATION_LAYERS.md) | [Roadmap](./0_spec/ROADMAP.md)

**Last Updated**: 2026-03-18
