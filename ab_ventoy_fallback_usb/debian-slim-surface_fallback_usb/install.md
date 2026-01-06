# Debian Slim Surface - Installation Guide

> **Purpose**: Lightweight recovery OS with Surface Pro support, AI tools, GUI
> **Base**: Debian 12 (Bookworm) minimal
> **Size**: ~1.2GB installed
> **Boot**: Select "Debian (Recovery)" from Ventoy/GRUB menu

---

## Quick Start

```sh
# Login as diego (password: 1234567890)
# Run setup script:
./install.sh surface   # Install Surface kernel FIRST
sudo reboot            # Keyboard works after this
./install.sh install   # Install all tools

# Start desktop:
startx
```

---

## Package Categories

### Surface Drivers (~500MB)
| Package | Description |
|---------|-------------|
| `linux-image-surface` | Surface-optimized kernel |
| `linux-headers-surface` | Kernel headers |
| `iptsd` | Intel touchscreen daemon |
| `libwacom-surface` | Wacom pen support |

### Base System (~100MB)
| Package | Description |
|---------|-------------|
| `systemd-sysv` | Init system |
| `dbus` | Message bus |
| `locales` | Locale data |
| `console-setup` | Console configuration |

### Shells (~15MB)
| Package | Description |
|---------|-------------|
| `bash` | Bourne Again Shell |
| `zsh` | Z Shell |
| `fish` | Friendly Interactive Shell |

### Editors (~30MB)
| Package | Description |
|---------|-------------|
| `vim` | Vi Improved |
| `nano` | Simple text editor |

### Networking (~50MB)
| Package | Description |
|---------|-------------|
| `network-manager` | Network management daemon |
| `wpasupplicant` | WPA authentication |
| `iwd` | iNet wireless daemon |
| `openssh-client` | SSH client |
| `openssh-server` | SSH server |
| `curl` | URL transfer tool |
| `wget` | File downloader |
| `git` | Version control |

### Graphics & Desktop (~200MB)
| Package | Description |
|---------|-------------|
| `xorg` | X11 display server |
| `openbox` | Lightweight window manager |
| `xterm` | Terminal emulator |
| `mesa-utils` | Mesa utilities |
| `fonts-dejavu` | DejaVu fonts |

### Browsers (~5MB)
| Package | Description |
|---------|-------------|
| `lynx` | Text browser |

### System Monitors (~5MB)
| Package | Description |
|---------|-------------|
| `btop` | Beautiful resource monitor |
| `htop` | Interactive process viewer |

### Development (~100MB)
| Package | Description |
|---------|-------------|
| `nodejs` | Node.js runtime |
| `npm` | Node package manager |
| `python3` | Python 3 interpreter |
| `python3-pip` | Python package installer |

### CLI Tools (~30MB)
| Package | Description |
|---------|-------------|
| `ripgrep` | Fast grep replacement |
| `fd-find` | Fast find replacement |
| `fzf` | Fuzzy finder |
| `jq` | JSON processor |
| `tmux` | Terminal multiplexer |
| `neofetch` | System info display |

### GUI Applications (~50MB)
| Package | Description |
|---------|-------------|
| `pcmanfm` | Lightweight file manager |
| `lxappearance` | GTK theme switcher |

### Utilities (~30MB)
| Package | Description |
|---------|-------------|
| `sudo` | Privilege escalation |
| `grub-efi-amd64` | EFI bootloader |
| `efibootmgr` | EFI boot manager |
| `dosfstools` | FAT filesystem tools |
| `e2fsprogs` | ext4 filesystem tools |
| `cryptsetup` | LUKS encryption |
| `btrfs-progs` | Btrfs tools |
| `parted` | Partition editor |

---

## NPM Packages (Global)

| Package | Description |
|---------|-------------|
| `@anthropic-ai/claude-code` | Claude Code CLI |

---

## Services Enabled

| Service | Description |
|---------|-------------|
| `NetworkManager` | Network management |
| `ssh` | SSH server |
| `iptsd` | Surface touchscreen |

---

## Why Debian over Alpine?

| Feature | Debian | Alpine |
|---------|--------|--------|
| **linux-surface** | Official repo | Community only |
| **Package count** | 59,000+ | 15,000 |
| **glibc** | Yes (better compat) | musl |
| **Node.js** | Full support | Some issues |
| **Size** | ~1.2GB | ~700MB |

Debian is preferred for Surface Pro because:
1. Official linux-surface support with apt repo
2. Better hardware compatibility (glibc)
3. More packages available (btop, etc.)
4. Easier troubleshooting

---

## Openbox Menu Structure

```
Right-click menu:
├── Terminal (xterm)
├── Files (pcmanfm)
├── AI Tools ─── Claude Code
├── System ───┬── btop
│             ├── WiFi (nmtui)
│             └── Unlock LUKS
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
| `sudo cryptsetup open /dev/nvme0n1p4 pool` | Unlock LUKS |
| `sudo mount /dev/mapper/pool /mnt/pool` | Mount pool |

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
sudo systemctl restart NetworkManager
nmtui
```

### No keyboard (Surface)
```sh
# Check if surface modules loaded
lsmod | grep surface

# If not, reboot with Surface kernel
sudo update-grub
sudo reboot
```

### No display
```sh
cat /var/log/Xorg.0.log | tail -50
X :0 &
xterm -display :0
```

---

## Recovery Tasks

This Debian installation is designed for:

1. **System Recovery** - Access main system files when OS fails
2. **AI Assistance** - Use Claude Code to diagnose and fix issues
3. **Network Diagnostics** - WiFi, SSH, curl for remote help
4. **Disk Operations** - Mount, fsck, resize partitions
5. **LUKS Access** - Unlock encrypted partitions

---

*Generated for Surface Pro 8 - Debian 12 (Bookworm)*
