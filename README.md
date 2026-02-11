# UNIX - Secure Workstation & Fallback Infrastructure

> **Device**: Surface Pro 8 (Intel Tiger Lake)
> **Goal**: A high-security, declarative, and immutable UNIX environment with multiple layers of fail-safe recovery.

---

## Security Zones

| Zone | System | Encryption | Purpose |
| :--- | :--- | :--- | :--- |
| **0** | **Alpine Recovery** | None | Emergency repair, LUKS rescue |
| **1a** | **Windows 11 Lite** | None | Hardware compatibility (Surface Webcam) |
| **1b** | **Kali Security** | None | Security auditing & pentesting |
| **2** | **NixOS (Host)** | LUKS2 | Primary Workstation (Impermanence) |
| **3** | **User Space** | LUKS + Vault | Personal data & secret management |
| **4** | **Untrusted** | LUKS | Isolated workloads via `microvm.nix` |

---

## Operating Systems

### NixOS Host — [`aa_nixos-surface_host/`](./aa_nixos-surface_host)
- **Immutable Root**: `tmpfs` wiped every boot.
- **Persistence**: `impermanence` module binds `@system/state` and `@user/home` to BTRFS subvolumes.
- **Declarative**: Everything defined via Nix Flakes (`flake.nix`, `configuration.nix`).
- **Desktop**: KDE Plasma 6 (Wayland) default, GNOME and Openbox available.
- **Kernel**: linux-surface (mainline 6.15+ with Surface patches).

### Arch Linux Fallback — [`ab_arch-surface_fallback_desk/`](./ab_arch-surface_fallback_desk)
Desktop fallback with Surface hardware support. Bootstrap scripts + install automation.

### Kali Security — [`ab_kali_security/`](./ab_kali_security)
Unencrypted partition for rapid security auditing and network forensics. Debootstrap-based install.

### Windows 11 Lite — [`ac_win11_webcam/`](./ac_win11_webcam)
Minimized Windows instance for Surface Pro 8 hardware driver support (webcam piping).

### Ventoy USB Recovery — [`ad_ventoy_fallback_usb/`](./ad_ventoy_fallback_usb)
Multi-OS recovery drive with `toram` support:
- **Debian Surface** — Full GUI recovery with `linux-surface` kernel
- **Arch Surface** — Rolling release recovery + AUR
- **Alpine Minimal** — Ultra-lightweight CLI rescue (~400MB)
- **NixOS Slim** — Minimal NixOS ISO builder

### Mobile / Android — [`ae_mobile_image/`](./ae_mobile_image)
BlissOS QEMU VM config, Samsung app extraction, OVMF firmware for Android virtualization.

---

## Nix Flakes (User Environment)

### Desktop — [`ba_flakes_desktop/`](./ba_flakes_desktop)

Standalone Home Manager configuration that works on **any Linux distro** (not just NixOS). Manages user-level packages, dotfiles, and desktop environments.

**Profiles** (modular, composable):

| Profile | Content |
|---------|---------|
| `shell-core` | zsh, starship, fzf, ripgrep, fd, bat, eza |
| `dev-languages` | Node, Python, Rust, Go runtimes |
| `build-debug` | cmake, gcc, gdb, valgrind, strace |
| `containers-cloud` | podman, kubectl, helm, gcloud, aws, oci-cli |
| `security-network` | nmap, wireshark, burpsuite, openssl |
| `data-science` | jupyter, pandas, numpy, R |
| `productivity` | obsidian, zotero, libreoffice |
| `media-graphics` | gimp, inkscape, ffmpeg, imagemagick |

**Host Configs**: `surface-plasma` (all profiles + Plasma 6), `surface-gnome`, `server`, `cli`, `minimal`.

### Termux — [`bb_flakes_termux/`](./bb_flakes_termux)

Nix Home Manager for Android/Termux. Mobile development environment with flake-based reproducibility.

---

## Applications

| Directory | Purpose |
|-----------|---------|
| [`da_app_cli/`](./da_app_cli) | CLI tools (Python Poetry + Nix containerization) |
| [`db_apps_gui_2/`](./db_apps_gui_2) | GUI apps via Docker, Podman, or host install (profiles: basic, min) |
| [`de_claude-sandbox/`](./de_claude-sandbox) | Claude AI sandbox (AppImage + Nix) |

---

## Repository Structure

```
unix/
├── 0_spec/                            # Specifications & design docs
│   ├── ARCHITECTURE.md                # System-wide design overview
│   ├── DISK_LAYOUT.md                 # Partition & subvolume map
│   ├── ISOLATION_LAYERS.md            # Sandbox technology breakdown
│   ├── ROADMAP.md                     # Progress & milestones
│   ├── TOOLS.md                       # Curated package lists
│   └── z_dotfiles_src/                # Dotfile templates
│
├── aa_nixos-surface_host/             # NixOS host configuration (Primary OS)
├── ab_arch-surface_fallback_desk/     # Arch Linux desktop fallback
├── ab_kali_security/                  # Kali Linux security zone
├── ac_win11_webcam/                   # Windows hardware fallback
├── ad_ventoy_fallback_usb/            # Multi-OS USB recovery builder
├── ae_mobile_image/                   # Mobile/Android image management
│
├── ba_flakes_desktop/                 # Nix Home Manager (desktop)
├── bb_flakes_termux/                  # Nix Home Manager (mobile/Termux)
│
├── da_app_cli/                        # CLI applications
├── db_apps_gui_2/                     # GUI applications (containers)
├── de_claude-sandbox/                 # Claude AI sandbox
│
└── z_archive/                         # Archived configs (old Kinoite host)
```

---

## Build System

Every major project uses `build.sh` (engine) + `build.json` (config) at project root.

```bash
# Rebuild NixOS system
~/git/unix/aa_nixos-surface_host/build.sh

# Rebuild Home Manager (desktop)
~/git/unix/ba_flakes_desktop/build.sh

# Rebuild Home Manager (Termux)
~/git/unix/bb_flakes_termux/build.sh
```

---

## Isolation Layers

1. **Nix Native** — Trusted CLI & system utilities
2. **Distrobox** — Development environments (Arch, Ubuntu)
3. **Flatpak** — Sandboxed GUI applications
4. **Podman** — Rootless containerized services
5. **MicroVM** — Fully isolated kernels for untrusted workloads

---

## Quick Links

- [Architecture Deep-Dive](./0_spec/ARCHITECTURE.md)
- [Partition & Disk Layout](./0_spec/DISK_LAYOUT.md)
- [Isolation Layers](./0_spec/ISOLATION_LAYERS.md)
- [USB Recovery Guide](./ad_ventoy_fallback_usb/README.md)
- [Home Manager Guide](./ba_flakes_desktop/a_spec/README.md)
- [System Roadmap](./0_spec/ROADMAP.md)
