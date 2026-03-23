# Arch Linux Surface - Installation Guide

> **Target**: Surface Pro 8 fallback/recovery OS
> **Partition**: nvme0n1p6 (5GB)
> **Key feature**: Surface keyboard WORKS (linux-surface drivers)

---

## Quick Start

```bash
# After booting Arch ISO with USB keyboard:

# 1. Install base Arch (see SETUP.md)
# 2. Copy install.tar to /home/diego/
# 3. Extract and run:

tar -xf install.tar
cd arch-install
./install.sh surface   # Install Surface drivers, then REBOOT
# After reboot, Surface keyboard works!
./install.sh install   # Install all tools
./install.sh desktop   # Start GUI
```

---

## Installation Order

### Phase 1: Base Arch Install (from ISO)
Use USB keyboard - Surface keyboard won't work yet!

1. Boot Arch ISO from Ventoy USB
2. Connect WiFi: `iwctl station wlan0 connect "SSID"`
3. Mount: `mount /dev/nvme0n1p6 /mnt`
4. Install base: `pacstrap -K /mnt base linux linux-firmware networkmanager vim sudo`
5. Configure: timezone, locale, hostname, root password
6. Install bootloader (systemd-boot or GRUB)
7. Reboot into installed Arch (still need USB keyboard)

### Phase 2: Surface Drivers
```bash
./install.sh surface
# This adds linux-surface repo and installs:
# - linux-surface (kernel with Surface patches)
# - linux-surface-headers
# - iptsd (touchscreen daemon)

sudo reboot
# After reboot: SURFACE KEYBOARD WORKS!
```

### Phase 3: All Tools
```bash
./install.sh scan      # Check what's missing
./install.sh install   # Install everything from install.json
```

### Phase 4: Desktop (Optional)
```bash
./install.sh desktop   # Start Openbox (X11)
./install.sh sway      # Start Sway (Wayland)
```

---

## What Gets Installed

### Surface Drivers (PRIORITY)
- `linux-surface` - Kernel with Surface patches
- `linux-surface-headers` - For building modules
- `iptsd` - Touchscreen daemon

### Shells
- bash, zsh, fish

### Editors
- vim, nano, neovim

### Network
- NetworkManager, wpa_supplicant, openssh, curl, wget, git

### CLI Tools
- ripgrep, fd, fzf, jq, tmux, neofetch, eza, bat, zoxide, htop, btop

### Development
- nodejs, npm, python, python-pip
- @anthropic-ai/claude-code (npm)

### Graphics (Optional)
- X11: xorg-server, openbox, xterm
- Wayland: sway, foot, wofi

---

## Recovery Commands

### Unlock LUKS (NixOS partition)
```bash
sudo cryptsetup open /dev/nvme0n1p4 pool
sudo mount /dev/mapper/pool /mnt -o subvol=@root-nixos
# Access NixOS files at /mnt
```

### Mount Kubuntu
```bash
sudo mount /dev/nvme0n1p5 /mnt/kubuntu
```

### SSH Access
```bash
# From another machine:
ssh diego@<arch-ip>
# Password: 1234567890
```

---

## Troubleshooting

### Surface keyboard not working
```bash
# Check if modules loaded
lsmod | grep surface

# If not, reinstall:
./install.sh surface
sudo reboot
```

### No WiFi
```bash
# Use NetworkManager
nmcli device wifi list
nmcli device wifi connect "SSID" password "pass"
```

### Boot issues
```bash
# From Arch ISO, chroot and fix:
mount /dev/nvme0n1p6 /mnt
arch-chroot /mnt
# Fix bootloader, fstab, etc.
```
