# Arch VM + Podman Container - Minimum Tools Reference

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  VM: archvm-minimum (4GB RAM, 2 CPUs, 20GB disk)           │
│  ├── Arch Linux (from cloud image)                          │
│  ├── Graphics: Openbox + SDDM                               │
│  ├── Apps: Konsole, Dolphin                                 │
│  ├── Container runtime: Podman                              │
│  └── ~/podman/                                              │
│       └── cloud-connect:minimum container                   │
│            ├── Privacy tools (tor, dnscrypt-proxy)          │
│            ├── Dev tools (python, rust, nodejs)             │
│            ├── AI CLIs (claude-code, gemini-cli)            │
│            └── GUI Apps (falkon, okular)                    │
└─────────────────────────────────────────────────────────────┘
```

---

## Resource Usage Summary

### VM (Host)

| Category | Storage | RAM (idle) | RAM (active) |
|----------|---------|------------|--------------|
| Base Arch | ~500 MB | ~100 MB | ~200 MB |
| Desktop (Openbox+SDDM) | ~200 MB | ~150 MB | ~300 MB |
| Podman Runtime | ~100 MB | ~50 MB | ~100 MB |
| GUI Apps (Konsole, Dolphin) | ~150 MB | ~0 MB | ~200 MB |
| **VM TOTAL** | **~950 MB** | **~300 MB** | **~800 MB** |

### Container (cloud-connect:minimum)

| Category | Storage | RAM (idle) | RAM (active) |
|----------|---------|------------|--------------|
| Base System | ~400 MB | ~30 MB | ~80 MB |
| CLI Tools | ~75 MB | ~0 MB | ~50 MB |
| Privacy Tools | ~205 MB | ~20 MB | ~100 MB |
| Compilers (rust, python) | ~800 MB | ~0 MB | ~300 MB |
| Package Managers (npm) | ~200 MB | ~20 MB | ~100 MB |
| AI Tools | ~200 MB | ~0 MB | ~150 MB |
| GUI Apps | ~150 MB | ~0 MB | ~200 MB |
| **CONTAINER TOTAL** | **~2 GB** | **~70 MB** | **~960 MB** |

### Combined Total

| Metric | Value |
|--------|-------|
| **Total Storage** | ~3 GB |
| **RAM (idle)** | ~370 MB |
| **RAM (active)** | ~1.8 GB |

---

## VM Packages (archvm-minimum)

### System & Network

| Package | Size | Description |
|---------|------|-------------|
| networkmanager | 15 MB | Network connection manager |
| openssh | 5 MB | SSH client/server |

### Desktop Environment

| Package | Size | Description |
|---------|------|-------------|
| xorg-server | 50 MB | X11 display server |
| xorg-xinit | 2 MB | X11 initializer |
| openbox | 5 MB | Lightweight window manager |
| sddm | 20 MB | Display manager |
| ttf-dejavu | 10 MB | DejaVu font family |
| breeze-icons | 100 MB | KDE icon theme |

### GUI Applications

| Package | Size | Description |
|---------|------|-------------|
| konsole | 30 MB | KDE terminal emulator |
| dolphin | 40 MB | KDE file manager |

### Settings Tools

| Package | Size | Description |
|---------|------|-------------|
| lxappearance | 5 MB | GTK theme/appearance settings |
| obmenu-generator | 2 MB | Openbox menu editor (AUR) |

### Container Runtime

| Package | Size | Description |
|---------|------|-------------|
| podman | 50 MB | Daemonless container runtime |
| podman-compose | 5 MB | Compose file support |
| fuse-overlayfs | 2 MB | Rootless overlay filesystem |
| slirp4netns | 2 MB | Rootless networking |
| crun | 2 MB | Fast OCI runtime |

### Build Tools (for AUR)

| Package | Size | Description |
|---------|------|-------------|
| base-devel | 300 MB | Build tools (gcc, make, etc.) |
| git | 50 MB | Version control |
| yay | 10 MB | AUR helper |

---

## Container Packages (cloud-connect:minimum)

### Base System

| Package | Size | Description |
|---------|------|-------------|
| base-devel | 300 MB | Build tools |
| git | 50 MB | Version control |
| sudo | 2 MB | Privilege escalation |
| curl | 5 MB | URL transfer tool |
| wget | 3 MB | File downloader |

### Shell & Utils

| Package | Size | Description |
|---------|------|-------------|
| bash | 8 MB | Default shell |
| zsh | 7 MB | Z Shell (extensible) |
| fish | 15 MB | Friendly Interactive Shell |
| coreutils | 20 MB | Basic utilities (ls, cat, cp) |
| findutils | 5 MB | find, xargs |
| grep | 2 MB | Pattern matching |
| sed | 1 MB | Stream editor |
| less | 1 MB | Pager |
| htop | 1 MB | Process monitor |
| jq | 1 MB | JSON processor |

### Editor & Tools

| Package | Size | Description |
|---------|------|-------------|
| vim | 30 MB | Text editor |
| unzip | 1 MB | Archive extraction |
| xclip | 1 MB | Clipboard utility |
| scrot | 1 MB | Screenshot tool |

### Network & Privacy

| Package | Size | Description |
|---------|------|-------------|
| iproute2 | 5 MB | IP routing utilities |
| iputils | 1 MB | Network diagnostics (ping) |
| openssh | 10 MB | SSH client |
| ca-certificates | 1 MB | SSL/TLS certificates |
| tor | 50 MB | Anonymity network |
| torsocks | 1 MB | Tor wrapper for apps |
| dnscrypt-proxy | 15 MB | Encrypted DNS |
| wireguard-tools | 5 MB | WireGuard VPN client |

### Languages & Runtimes

| Package | Size | Description |
|---------|------|-------------|
| python | 100 MB | Python 3 interpreter |
| python-pip | 20 MB | Python package installer |
| python-pipx | 10 MB | Isolated Python CLI tools |
| nodejs | 80 MB | JavaScript runtime |
| npm | 50 MB | Node package manager |
| rust | 500 MB | Rust compiler |
| cargo | (with rust) | Rust package manager |

### AI Tools (via npm)

| Package | Size | Description |
|---------|------|-------------|
| @anthropic-ai/claude-code | 100 MB | Claude AI CLI |
| @google/gemini-cli | 50 MB | Gemini AI CLI |

### GUI Applications

| Package | Size | Description |
|---------|------|-------------|
| konsole | 30 MB | Terminal emulator |
| falkon | 50 MB | Lightweight browser |
| dolphin | 50 MB | File manager |
| okular | 80 MB | PDF/document viewer |
| breeze-icons | 100 MB | KDE icon theme |

---

## Openbox Menu Structure

```
Right-click Desktop Menu:
├── Konsole
├── Dolphin
├── Falkon Browser
├── ─────────────
├── Settings
│   ├── Appearance (lxappearance)
│   ├── Menu Editor (obmenu-generator)
│   └── Regenerate Menu
├── Container
│   ├── Build Container
│   ├── Start Container
│   ├── Enter Container
│   └── Stop Container
├── ─────────────
└── System
    ├── Logout
    ├── Reboot
    └── Shutdown
```

---

## Container Commands

```bash
# Inside VM: ~/podman/
./build.sh build    # Build container image
./build.sh start    # Start container
./build.sh shell    # Enter container shell
./build.sh stop     # Stop container
./build.sh status   # Show container status
./build.sh clean    # Remove container and image
```

---

## System Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| **VM Disk** | 10 GB | 20 GB |
| **VM RAM** | 2 GB | 4 GB |
| **VM CPUs** | 1 | 2 |
| **Host RAM** | 6 GB | 8 GB |
| **Host Disk** | 25 GB | 40 GB |

---

## Notes

- **VM** runs Openbox desktop with minimal footprint
- **Container** provides isolated anonymous/clean profile
- Privacy tools (tor, dnscrypt-proxy) run inside container
- AI CLIs available via npm global install
- GUI apps share X11 display from VM
- All configs in `~/.config/openbox/`
