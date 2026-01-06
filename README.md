# UNIX - Secure Workstation & Fallback Infrastructure

> **Device**: Surface Pro 8 (Intel Tiger Lake)
> **Goal**: A high-security, declarative, and immutable UNIX environment with multiple layers of fail-safe recovery.

---

## 🏗️ Architecture Overview

This repository manages the full lifecycle of a Surface Pro 8 workstation, from the primary immutable OS to emergency USB recovery tools. It is designed with **Defense in Depth** and **Semantic Isolation** at its core.

### 🛡️ Security Zones

| Zone | System | Encryption | Purpose |
| :--- | :--- | :--- | :--- |
| **0** | **Alpine Recovery** | None | Emergency repair, LUKS rescue |
| **1a** | **Windows 11 Lite** | None | Hardware compatibility (Surface Webcam) |
| **1b** | **Kali Security** | None | Security auditing & pentesting |
| **2** | **NixOS (Host)** | LUKS2 | Primary Workstation (Impermanence) |
| **3** | **User Space** | LUKS + Vault | Personal data & secret management |
| **4** | **Untrusted** | LUKS | Isolated workloads via `microvm.nix` |

---

## 🚀 Operating Systems

### 1. [NixOS Host](./a_nixos_host) (Primary)
- **Immutable Root**: `tmpfs` (2GB RAM) wiped every boot.
- **Persistence**: `impermanence` module binds `@system/state` and `@user/home` to BTRFS subvolumes.
- **Declarative**: Everything defined via Nix Flakes.
- **Desktop**: KDE Plasma (Wayland) default, with GNOME, Waydroid, and Brave Kiosk options.

### 2. [Ventoy USB Fallback](./ab_ventoy_fallback_usb) (Emergency)
A multi-OS recovery drive capable of loading entirely to RAM (`toram` mode).
- **Debian Surface**: Full GUI recovery with `linux-surface` kernel support.
- **Arch Surface**: Rolling release recovery for development and AUR access.
- **Alpine Minimal**: Ultra-lightweight CLI rescue system (~400MB).

### 3. [Kali Security](./a_kali_security)
Unencrypted partition for rapid security auditing and network forensics.

### 4. [Windows 11 Lite](./a_win11_webcam)
Minimized Windows instance specifically for Surface Pro 8 hardware driver support (Webcam piping).

---

## 📂 Repository Structure

```text
unix/
├── 0_spec/                 # 📖 Core Specifications
│   ├── ARCHITECTURE.md     # System-wide design overview
│   ├── DISK_LAYOUT.md      # Partition & Subvolume map
│   ├── ROADMAP.md          # Implementation & Task tracking
│   └── TOOLS.md            # Curated package lists
├── a_nixos_host/           # ❄️ NixOS Configuration (Primary OS)
├── a_kali_security/        # 🐉 Kali Linux Security Environment
├── a_win11_webcam/         # 🪟 Windows Hardware Fallback
├── ab_ventoy_fallback_usb/ # 🛠️ Multi-OS USB Recovery Builder
├── b_apps/                 # 📦 App configurations (Flatpak, Podman)
└── b_mnt/                  # 🔗 Mount & Storage management scripts
```

---

## 🔐 Security & Isolation

We employ a multi-layered approach to application isolation:

1.  **Nix Native**: Trusted CLI & system utilities.
2.  **Distrobox**: Development environments (Arch, Ubuntu).
3.  **Flatpak**: Sandboxed GUI applications (Browsers, Discord).
4.  **Podman**: Rootless containerized services.
5.  **MicroVM**: Fully isolated kernels for untrusted workloads.

---

## 🛠️ Quick Links

- [Architecture Deep-Dive](./0_spec/ARCHITECTURE.md)
- [USB Recovery Guide](./ab_ventoy_fallback_usb/README.md)
- [Partition & Disk Layout](./0_spec/DISK_LAYOUT.md)
- [System Roadmap](./0_spec/ROADMAP.md)

---
*Maintained for Surface Pro 8 - 2026*