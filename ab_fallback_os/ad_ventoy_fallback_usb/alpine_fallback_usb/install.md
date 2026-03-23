# Alpine Recovery - Installation Guide

> **Purpose**: Lightweight recovery OS with AI tools, GUI, and access to main system
> **Size**: ~700MB installed
> **Boot**: Select "Alpine Linux (Recovery)" from GRUB menu

---

## Quick Start

```sh
# Login as diego (password: 1234567890)
# Run setup script:
./install.sh

# Start desktop:
startx
```

---

## Package Categories

### Base System (~150MB)
| Package | Description |
|---------|-------------|
| `alpine-base` | Core Alpine Linux |
| `linux-lts` | LTS kernel 6.12.x |
| `openrc` | Init system |

### Shells (~15MB)
| Package | Description |
|---------|-------------|
| `bash` | Bourne Again Shell |
| `zsh` | Z Shell with completions |
| `fish` | Friendly Interactive Shell |

### Editors (~30MB)
| Package | Description |
|---------|-------------|
| `vim` | Vi Improved |
| `nano` | Simple text editor |

### Networking (~50MB)
| Package | Description |
|---------|-------------|
| `networkmanager` | Network management daemon |
| `networkmanager-wifi` | WiFi support |
| `wpa_supplicant` | WPA authentication |
| `openssh` | SSH client/server |
| `curl` | URL transfer tool |
| `wget` | File downloader |
| `git` | Version control |

### Graphics & Desktop (~200MB)
| Package | Description |
|---------|-------------|
| `xorg-server` | X11 display server |
| `xinit` | X initialization |
| `openbox` | Lightweight window manager |
| `xterm` | Terminal emulator |
| `mesa-dri-gallium` | GPU drivers |
| `ttf-dejavu` | Font family |

### Browsers (~10MB)
| Package | Description |
|---------|-------------|
| `dillo` | Ultra-lightweight GUI browser (~2MB) |
| `links` | Text browser with graphics mode |

### System Monitors (~5MB)
| Package | Description |
|---------|-------------|
| `btop` | Beautiful resource monitor |
| `htop` | Interactive process viewer |

### Development (~100MB)
| Package | Description |
|---------|-------------|
| `nodejs` | Node.js v22 runtime |
| `npm` | Node package manager |
| `python3` | Python 3 interpreter |
| `py3-pip` | Python package installer |

### CLI Tools (~30MB)
| Package | Description |
|---------|-------------|
| `ripgrep` | Fast grep replacement (rg) |
| `fd` | Fast find replacement |
| `fzf` | Fuzzy finder |
| `jq` | JSON processor |
| `yq` | YAML processor |
| `tmux` | Terminal multiplexer |
| `neofetch` | System info display |

### GUI Applications (~50MB)
| Package | Description |
|---------|-------------|
| `pcmanfm` | Lightweight file manager |
| `lxappearance` | GTK theme switcher |
| `adwaita-icon-theme` | Default icon theme |

### Utilities (~20MB)
| Package | Description |
|---------|-------------|
| `util-linux` | Core utilities |
| `e2fsprogs` | ext4 filesystem tools |
| `dosfstools` | FAT filesystem tools |
| `grub` | Bootloader |
| `grub-efi` | EFI bootloader |
| `sudo` | Privilege escalation |

---

## NPM Packages (Global)

| Package | Description |
|---------|-------------|
| `@anthropic-ai/claude-code` | Claude Code CLI |
| `gemini-cli` | Google Gemini CLI |

---

## Services Enabled

| Service | Description |
|---------|-------------|
| `dbus` | Message bus system |
| `networkmanager` | Network management |
| `sshd` | SSH server |

---

## Openbox Menu Structure

```
Right-click menu:
├── Terminal (xterm)
├── Files (pcmanfm)
├── Dillo (browser)
├── Links (browser)
├── AI Tools ─┬── Claude Code
│             └── Gemini
├── System ───┬── btop
│             ├── htop
│             ├── WiFi (nmtui)
│             └── Mount Kubuntu
└── Exit
```

---

## Key Commands

| Command | Description |
|---------|-------------|
| `startx` | Start Openbox desktop |
| `claude` | Launch Claude Code CLI |
| `nmtui` | WiFi configuration TUI |
| `btop` | System monitor |
| `sudo mount /mnt/kubuntu` | Mount Kubuntu partition |

---

## Filesystem Layout

```
/                    Alpine root (5GB, ext4)
├── /boot            Shared boot partition (2GB)
├── /boot/efi        EFI system partition (100MB)
├── /home/diego      User home
│   ├── install.sh   Setup script
│   └── install.md   This file
└── /mnt/kubuntu     Mount point for Kubuntu (118GB)
```

---

## Credentials

| User | Password |
|------|----------|
| root | 1234567890 |
| diego | 1234567890 |

**Change passwords after first boot:**
```sh
passwd          # Change current user
sudo passwd root  # Change root
```

---

## Troubleshooting

### No WiFi
```sh
sudo rc-service networkmanager restart
nmtui
```

### No display
```sh
# Check Xorg log
cat /var/log/Xorg.0.log | tail -50

# Try basic X
X :0 &
xterm -display :0
```

### Mount errors
```sh
# Check partition
lsblk
sudo fsck /dev/nvme0n1p5  # Kubuntu partition
```

---

## Recovery Tasks

This Alpine installation is designed for:

1. **System Recovery** - Access Kubuntu/NixOS files when main OS fails
2. **AI Assistance** - Use Claude Code to diagnose and fix issues
3. **Network Diagnostics** - WiFi, SSH, curl for remote help
4. **Disk Operations** - Mount, fsck, resize partitions
5. **Lightweight Desktop** - Browse docs, manage files

---

*Generated for Surface Pro 8 - Alpine 3.21*
