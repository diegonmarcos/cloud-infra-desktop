# System Migration Plan: 95% → 55%

## Current State (92% after initial cleanup)

```
/dev/nvme0n1p5  116G  101G  9.5G  92% /
```

**Target: ~64G used (55%)**
**Need to free: ~37G**

---

## Space Analysis

| Location | Size | Action |
|----------|------|--------|
| `/var/lib/docker` | 29G | Clean unused, keep Distrobox |
| `/nix` | 18G | Remove (tools move to container) |
| `/var/lib/libvirt` | 6.5G | Move VMs to pool or remove |
| Old kernels (6.8.0-*) | ~5G | Remove |
| Dev packages (llvm, clang-dev, etc.) | ~3G | Move to container |
| GUI apps (installed via apt) | ~3G | Move to Flatpak |
| `~/.local/share/pipx` | 1.1G | Move to container |
| `~/.nvm` | 1.5G | Move to container |
| `~/.rustup` | 1.5G | Move to container |
| `~/.local/lib/python*` | 551M | Move to Poetry/container |

**Estimated savings: ~50G**

---

## Target Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Kubuntu Host (~15GB)                                        │
│ ├── kubuntu-desktop (KDE Plasma)                            │
│ ├── linux-surface kernel (current only)                     │
│ ├── Podman + Distrobox                                      │
│ ├── Flatpak runtime                                         │
│ └── Basic system utils                                      │
└─────────────────────────────────────────────────────────────┘
            │                           │
            ▼                           ▼
┌─────────────────────────┐  ┌─────────────────────────────────┐
│ Distrobox (~15GB)       │  │ Flatpak (~20GB)                 │
│ /home/diego/app_cli     │  │ /home/diego/app_gui             │
│                         │  │                                 │
│ • gcc, clang, rustc     │  │ • VSCode / Windsurf             │
│ • llvm, cmake, make     │  │ • Brave / Chrome                │
│ • Python + Poetry       │  │ • Obsidian                      │
│ • Node.js + npm         │  │ • Discord / Slack               │
│ • Go, Java, Ruby        │  │ • LibreOffice                   │
│ • Git, gh, dev tools    │  │ • GIMP, etc.                    │
└─────────────────────────┘  └─────────────────────────────────┘
```

---

## Phase 1: Remove Old Kernels (~5G)

```bash
# List installed kernels
dpkg -l | grep linux-image

# Keep only current surface kernel, remove old ubuntu kernels
sudo apt purge linux-image-6.8.0-*
sudo apt purge linux-modules-6.8.0-*
sudo apt purge linux-modules-extra-6.8.0-*

# Also remove old surface kernels (keep latest only)
# sudo apt purge linux-image-6.10.3-surface-1
# sudo apt purge linux-image-6.10.5-surface-1
# sudo apt purge linux-image-6.17.1-surface-2
```

---

## Phase 2: Move GUI Apps to Flatpak (~3G)

### Remove apt versions:
```bash
sudo apt purge windsurf code brave-browser google-chrome-stable \
    obsidian discord slack-desktop libreoffice-*
```

### Install Flatpak versions:
```bash
flatpak install flathub com.visualstudio.code
flatpak install flathub com.brave.Browser
flatpak install flathub md.obsidian.Obsidian
flatpak install flathub com.discordapp.Discord
flatpak install flathub com.slack.Slack
flatpak install flathub org.libreoffice.LibreOffice
```

---

## Phase 3: Move Dev Tools to Container (~10G)

### Remove from host:
```bash
# Compilers & dev libs (will be in Nix container)
sudo apt purge gcc g++ clang clang-tidy llvm-* libclang-* \
    cmake ninja-build meson bear valgrind gdb lldb \
    openjdk-21-jdk nodejs npm ruby ruby-full jekyll \
    doxygen graphviz texlive

# Dev libraries
sudo apt purge libgtk-4-dev libadwaita-1-dev freeglut3-dev \
    libgl1-mesa-dev libvulkan-dev libpipewire-0.3-dev \
    libgstreamer*-dev libcairo2-dev libpango1.0-dev
```

### These stay in Nix container (already configured in container.nix)

---

## Phase 4: Clean Python/Node/Rust from Host (~4G)

```bash
# Remove pipx (tools move to container)
pipx uninstall-all
rm -rf ~/.local/share/pipx

# Remove pip packages (use Poetry in container)
pip3 uninstall -y numpy scipy opencv-python opencv-contrib-python \
    python-docx openpyxl lxml qrcode pyzbar pypotrace
rm -rf ~/.local/lib/python*

# Remove nvm (Node in container)
rm -rf ~/.nvm

# Remove rustup (Rust in container)
rm -rf ~/.rustup ~/.cargo
```

---

## Phase 5: Clean Nix from Root (~18G)

```bash
# If using Nix on host, remove it (tools now in container)
# WARNING: Only do this after container is working!

# Remove Nix
/nix/nix-installer uninstall

# Or manual removal
sudo rm -rf /nix
rm -rf ~/.nix-* ~/.config/nix
```

---

## Phase 6: Clean Docker (~15G+)

```bash
# Remove containers not needed
docker rm diego-dev  # Old dev container (replaced by Distrobox)
docker rm palantir-monitor palantir-cron  # If not needed

# Remove unused images
docker image prune -a

# Clean build cache
docker builder prune -a
```

---

## Phase 7: Clean Libvirt (~6.5G)

```bash
# List VMs
virsh list --all

# Remove unused VMs (or move to pool)
virsh undefine <vm-name> --remove-all-storage

# Or move VM images to pool
sudo mv /var/lib/libvirt/images/* /media/diego/pool/@shared/vms/
```

---

## Phase 8: Final Cleanup

```bash
# Remove orphaned packages
sudo apt autoremove --purge

# Clean apt
sudo apt clean

# Remove old snaps (if any)
sudo snap list --all | awk '/disabled/{print $1, $3}' | \
    while read snapname revision; do
        sudo snap remove "$snapname" --revision="$revision"
    done
```

---

## Expected Result

| Component | Before | After |
|-----------|--------|-------|
| Root (/) | 101G (92%) | ~60G (55%) |
| Docker | 29G | ~15G |
| /nix | 18G | 0G |
| Old kernels | ~5G | 0G |
| Dev packages | ~3G | 0G |
| pip/nvm/rustup | ~4G | 0G |

**Total freed: ~40G**

---

## Post-Migration Workflow

```bash
# Enter dev container
distrobox enter dev

# Python development
cd ~/app_cli/poetry_venv_1
poetry shell
python script.py

# C/C++ development
gcc -o program program.c

# Use Flatpak GUI apps
flatpak run com.visualstudio.code
# Or just: code (if exported)
```

---

## Rollback

If something breaks:
1. GUI apps: `flatpak uninstall` + `sudo apt install`
2. Dev tools: `sudo apt install build-essential`
3. Container: Rebuild with `./scripts/setup.sh rebuild`
