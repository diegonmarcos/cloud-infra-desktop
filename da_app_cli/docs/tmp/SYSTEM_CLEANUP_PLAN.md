# System Cleanup & Containerization Plan

**Objective**: Strip Kubuntu to minimal KDE Plasma + migrate all user tools to containers

**Strategy**:
- **System**: Minimal Kubuntu + KDE Plasma Desktop Environment
- **app_cli**: CLI development tools (Nix)
- **app_gui**: GUI applications (Flatpak)

---

## Current State Analysis

### Package Statistics
- **Total manually installed**: 496 packages
- **System utilities**: ~50 packages
- **KDE Desktop**: ~80 packages
- **Development tools**: ~40 packages
- **User CLI tools**: ~30 packages
- **User GUI apps**: ~20 packages
- **Libraries**: ~270 packages (dependencies)

### Storage Distribution
- **System**: ~15 GB (OS + libs + snap)
- **Docker**: 38 GB (primary container system)
- **User containers**: 2 GB (app_gui + app_cli)
- **Home**: ~18 GB (dotfiles + files)

---

## Category 1: KEEP ON SYSTEM (Minimal Kubuntu + KDE)

### Core System (Essential)
```
# Base system
ubuntu-minimal, ubuntu-standard
linux-generic, grub-efi-amd64-signed
systemd, udev, dbus
network-manager, wireless-tools
ca-certificates, openssh-client
sudo, bash, coreutils, util-linux
```

### KDE Plasma Desktop (Minimal)
```
# Display server & session
xorg, sddm, plasma-desktop

# Essential KDE apps (keep for system integration)
konsole              # Terminal (needed for recovery)
dolphin              # File manager (KDE integrated)
kate                 # Text editor (lightweight, system admin)
systemsettings       # KDE system settings
plasma-nm            # Network management
plasma-pa            # Audio management
powerdevil           # Power management
bluedevil            # Bluetooth
kscreen              # Display management

# KDE frameworks (auto-dependency)
kio, kwin, plasma-workspace

# File system support
ntfs-3g, exfatprogs, btrfs-progs
```

### System Utilities (Keep)
```
gparted              # Partition manager (system maintenance)
baobab               # Disk usage analyzer
grub-customizer      # Boot manager (system-level)
ufw                  # Firewall (system-level)
```

**Estimated size after cleanup**: ~12 GB (vs current 15 GB)

---

## Category 2: MIGRATE TO app_cli (CLI Tools via Nix)

### Development Tools
```nix
# Version control
git, git-lfs, gh (GitHub CLI)

# Programming languages
python3, nodejs, npm, go, rust, cargo

# Package managers
pip, pipx, npm, cargo

# Build tools
cmake, make, gcc, g++

# Runtime environments
dotnet-sdk, java-jdk
```

### CLI Utilities (User Tools)
```nix
# File operations
rsync, rclone, unzip, zip, p7zip, tar

# System monitoring
htop, btop, ncdu, duf, dust

# Text processing
vim, neovim, jq, yq, ripgrep, fd, bat

# Network tools
curl, wget, httpie, nmap, netcat

# Terminal multiplexers
tmux, screen, zellij

# Shell enhancements
fish, zsh, starship, zoxide, fzf, eza

# Cloud CLIs
gcloud, oci-cli, aws-cli, gh
```

### Container Tools
```nix
# These might stay system-level OR move to Nix
docker, podman, distrobox
kubectl, helm
```

**Current state**: app_cli is 116 KB (mostly empty)
**Target state**: ~2 GB with all Nix packages

---

## Category 3: MIGRATE TO app_gui (GUI Apps via Flatpak)

### Currently in Snap (migrate to Flatpak)
```flatpak
# Browser
org.mozilla.firefox → com.brave.Browser (already installed)
                    OR org.mozilla.firefox (flatpak)

# Other snaps
(review snap list for migration candidates)
```

### Development IDEs (if installed system-wide)
```flatpak
com.visualstudio.code
com.cursor.Cursor (if exists)
org.kde.kdevelop
```

### Productivity Apps (if installed)
```flatpak
org.libreoffice.LibreOffice
org.mozilla.Thunderbird
com.slack.Slack
com.discordapp.Discord
us.zoom.Zoom
org.telegram.desktop
```

### Media Apps (if installed)
```flatpak
org.videolan.VLC
org.gimp.GIMP
org.inkscape.Inkscape
org.audacityteam.Audacity
com.obsproject.Studio (OBS)
```

### KDE Apps (optional - move to Flatpak)
```flatpak
# Optional: Keep system versions OR flatpak versions
org.kde.okular       # PDF viewer
org.kde.gwenview     # Image viewer
org.kde.ark          # Archive manager
org.kde.kcalc        # Calculator
org.kde.spectacle    # Screenshot tool
```

**Current state**: app_gui is 2 GB (some flatpaks already installed)
**Target state**: ~5-8 GB with all user applications

---

## Category 4: REMOVE FROM SYSTEM

### User-Installed CLI Tools (migrate to app_cli)
```bash
# These should be removed from APT after migration to Nix
apt remove btop curl-dev htop ncdu rsync tree vim-gtk3 zip unzip
apt remove nodejs npm python3-pip pipx
apt remove docker.io podman
```

### Snap Packages (evaluate & remove)
```bash
# After migrating Firefox to Flatpak
snap remove firefox
snap remove gnome-42-2204 gtk-common-themes  # No longer needed
```

### Unused Libraries
```bash
# After removing user tools, auto-remove dependencies
apt autoremove
apt autoclean
```

### Cache & Temporary Files
```bash
# System cache
apt clean                    # APT cache
journalctl --vacuum-time=7d  # Old logs

# User cache
rm -rf ~/.cache/*           # 1.1 GB
rm -rf ~/.npm               # 74 MB (migrate to Nix)
rm -rf ~/.cargo             # If not used
```

**Estimated recovery**: 5-8 GB

---

## Migration Roadmap

### Phase 1: Prepare Containers ✓
- [x] app_cli structure exists (116 KB)
- [x] app_gui structure exists (2 GB)
- [ ] Configure Nix in app_cli
- [ ] Document Flatpak in app_gui

### Phase 2: Inventory & Test
1. **Audit current tools**:
   ```bash
   # List all manually installed packages
   apt-mark showmanual > ~/system-packages-before.txt

   # List all binaries in PATH
   compgen -c | sort -u > ~/binaries-before.txt

   # List all snaps
   snap list > ~/snap-before.txt
   ```

2. **Test container access**:
   ```bash
   # Verify app_cli Nix works
   cd ~/app_cli && nix-shell

   # Verify app_gui Flatpak works
   flatpak list --app
   ```

### Phase 3: Migrate CLI Tools (app_cli)
1. **Setup Nix environment**:
   ```bash
   cd ~/app_cli
   # Create shell.nix or flake.nix with all CLI tools
   ```

2. **Test each tool in Nix**:
   ```bash
   nix-shell -p btop htop ncdu rsync vim git nodejs python3
   ```

3. **Create activation script**:
   ```bash
   # ~/app_cli/activate.sh
   export PATH="$HOME/app_cli/bin:$PATH"
   alias activate-cli='nix-shell ~/app_cli/shell.nix'
   ```

4. **Remove from system**:
   ```bash
   apt remove btop htop ncdu rsync tree vim nodejs npm python3-pip
   apt autoremove
   ```

### Phase 4: Migrate GUI Apps (app_gui)
1. **Install Flatpak alternatives**:
   ```bash
   # Example: Firefox
   flatpak install flathub org.mozilla.firefox
   snap remove firefox
   ```

2. **Test each application**:
   ```bash
   flatpak run org.mozilla.firefox
   ```

3. **Create desktop entries**:
   ```bash
   # Flatpak automatically creates .desktop files
   # Verify in ~/.local/share/applications/
   ```

4. **Remove snaps**:
   ```bash
   snap remove firefox gnome-42-2204 gtk-common-themes
   ```

### Phase 5: System Cleanup
1. **Remove unused packages**:
   ```bash
   apt autoremove
   apt autoclean
   ```

2. **Clean caches**:
   ```bash
   apt clean
   rm -rf ~/.cache/*
   journalctl --vacuum-time=7d
   ```

3. **Verify minimal system**:
   ```bash
   apt-mark showmanual > ~/system-packages-after.txt
   diff ~/system-packages-before.txt ~/system-packages-after.txt
   ```

### Phase 6: Docker Cleanup
1. **Audit Docker usage**:
   ```bash
   docker system df
   docker images
   docker ps -a
   ```

2. **Clean unused**:
   ```bash
   docker system prune -a --volumes
   # Expected recovery: 5-15 GB
   ```

---

## Expected Results

### Storage After Cleanup
| Category | Before | After | Change |
|----------|--------|-------|--------|
| System | 15 GB | 12 GB | **-3 GB** |
| Docker | 38 GB | 25 GB | **-13 GB** (after prune) |
| app_cli | 116 KB | 2 GB | +2 GB |
| app_gui | 2 GB | 6 GB | +4 GB |
| Home dotfiles | 8.8 GB | 6 GB | **-2.8 GB** (cache cleanup) |
| **Total Used** | **75 GB** | **~55 GB** | **-20 GB** |

### Benefits
1. **Portable development environment** - Nix ensures reproducibility
2. **Isolated GUI apps** - Flatpak sandboxing
3. **Clean system** - Minimal attack surface
4. **Easy reinstall** - Just restore app_cli + app_gui configs
5. **Version control** - Nix and Flatpak manage versions

---

## Maintenance Strategy

### Daily Operations
```bash
# Activate CLI environment
source ~/app_cli/activate.sh  # or nix-shell

# Run GUI apps
flatpak run org.mozilla.firefox
```

### Updates
```bash
# System updates (minimal)
apt update && apt upgrade

# CLI tools (Nix)
cd ~/app_cli && nix-shell --update

# GUI apps (Flatpak)
flatpak update
```

### Backup Strategy
```bash
# Backup container configs
tar czf ~/backup-containers.tar.gz ~/app_cli ~/app_gui

# System is minimal - no backup needed (easy reinstall)
```

---

## Implementation Notes

### Nix Setup (app_cli)
```nix
# ~/app_cli/shell.nix
{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    # Development
    git gh nodejs python3 go rustc cargo

    # CLI utilities
    btop htop ncdu rsync vim neovim
    jq yq ripgrep fd bat eza fzf
    curl wget httpie
    tmux zellij

    # Cloud CLIs
    google-cloud-sdk
    # oci-cli (custom package)
  ];

  shellHook = ''
    echo "CLI tools environment activated"
    export PATH="$PWD/bin:$PATH"
  '';
}
```

### Flatpak Configuration (app_gui)
```bash
# ~/app_gui/install.sh
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Install apps
flatpak install -y flathub \
  org.mozilla.firefox \
  com.visualstudio.code \
  org.libreoffice.LibreOffice \
  org.videolan.VLC
```

---

## Risks & Mitigation

| Risk | Mitigation |
|------|------------|
| Container tools break | Keep docker/podman on system temporarily |
| Nix learning curve | Start with simple shell.nix, expand gradually |
| Flatpak missing apps | Keep system version until flatpak confirmed working |
| System breaks | Create Timeshift backup before cleanup |
| Performance overhead | Nix/Flatpak have minimal overhead vs native |

---

## Next Steps

1. **Review this plan** - Verify categorization is correct
2. **Setup Nix in app_cli** - Create initial shell.nix
3. **Test migration** - Migrate 1-2 tools as proof of concept
4. **Document process** - Record any issues
5. **Execute migration** - Follow phase-by-phase
6. **Verify system** - Ensure all tools accessible
7. **Cleanup** - Remove old packages
8. **Monitor** - Check for missing functionality

---

## Questions to Answer

1. **Docker placement**: Keep on system OR migrate to Nix/Flatpak?
   - **Recommendation**: Keep on system (system-level daemon)

2. **KDE apps**: System versions OR Flatpak versions?
   - **Recommendation**: System (better desktop integration)

3. **Compilers**: System OR Nix?
   - **Recommendation**: Nix (per-project environments)

4. **Cloud CLIs**: System OR Nix?
   - **Recommendation**: Nix (reproducible across machines)

---

*Document Version: 1.0*
*Date: 2026-01-09*
*Status: Planning Phase*
