# Ventoy Fallback USB - Multi-OS Recovery Drive

> Boot multiple recovery OSes from a single USB drive. All systems load to RAM for fast operation.

---

## Included Operating Systems

| OS | Size | RAM (toram) | RAM (normal) | Surface Support |
|----|------|-------------|--------------|-----------------|
| **Debian Surface** | ~800MB | 3.2GB free | 3.8GB free | linux-surface kernel |
| **Arch Surface** | ~1.2GB | 2.8GB free | 3.6GB free | linux-surface kernel |
| **Alpine Minimal** | ~400MB | 3.6GB free | 3.9GB free | Generic kernel |

### Boot Menu (Ventoy)

```
Debian Surface - Load to RAM (~800MB)     <- Removes USB after load
Debian Surface - Normal Boot              <- USB must stay plugged

Arch Surface - Load to RAM (~1.2GB)
Arch Surface - Normal Boot

Alpine Minimal - Load to RAM (~400MB)
Alpine Minimal - Normal Boot

─────────────────────────────────
Boot from local disk
Reboot
Shutdown
```

---

## Quick Start

### 1. Install Ventoy to USB
```bash
cd ventoy_install
sudo ./install_ventoy.sh /dev/sdX
```

### 2. Build Live ISOs
```bash
# Debian Surface (recommended for Surface Pro)
cd debian-slim-surface_fallback_usb
sudo ./build_live.sh

# Arch Surface (if on Arch host)
cd a_arch-surface_fallback_usb
sudo ./build_live.sh

# Alpine (lightweight, runs anywhere)
cd alpine_fallback_usb
sudo ./build_live.sh
```

### 3. Copy ISOs to Ventoy
```bash
sudo mount /dev/sdX1 /mnt
sudo cp */dist/*.iso /mnt/
sudo umount /mnt
```

### 4. Boot from USB
- Insert USB, boot device
- Select OS from Ventoy menu
- Choose "toram" option to load entirely to RAM

---

## Directory Structure

```
ab_ventoy_fallback_usb/
├── README.md                          # This file
├── ventoy_install/                    # Ventoy installer + config
│   ├── install_ventoy.sh              # Automated installer
│   ├── ventoy/
│   │   ├── ventoy.json                # Menu aliases + tips
│   │   └── ventoy_grub.cfg            # Custom GRUB entries
│   └── README.md                      # Ventoy setup guide
├── debian-slim-surface_fallback_usb/  # Debian + Surface
│   ├── build_live.sh                  # ISO builder
│   ├── install.json                   # Package config
│   ├── install.sh                     # Post-boot setup
│   └── install.md                     # Documentation
├── a_arch-surface_fallback_usb/       # Arch + Surface
│   ├── build_live.sh                  # ISO builder (archiso)
│   ├── install.json                   # Package config
│   ├── install.sh                     # Post-boot setup
│   └── SETUP.md                       # Arch setup guide
└── alpine_fallback_usb/               # Alpine minimal
    ├── build_live.sh                  # ISO builder (mkimage)
    ├── install.json                   # Package config
    └── install.md                     # Documentation
```

---

## Surface Pro 8 Notes

### What Works
- **Keyboard**: Works with linux-surface kernel
- **Touchscreen**: Works with iptsd service
- **WiFi**: Works with linux-surface firmware
- **Display**: Works with mesa drivers

### UEFI Settings
1. **Secure Boot**: Must be **disabled**
2. **Boot Order**: USB first
3. **Volume buttons**: Up+Power for UEFI access

---

## Default Credentials

All systems use the same credentials:

| User | Password |
|------|----------|
| `root` | `1234567890` |
| `diego` | `1234567890` |

**Change immediately after setup!**

---

## When to Use Each OS

### Debian Surface
- Full system recovery with GUI
- Best Surface Pro support
- Claude Code + node.js available
- Network diagnostics (curl, wget, ssh)

### Arch Surface
- Rolling release, latest packages
- Both Openbox and Sway (Wayland)
- Best for developers
- AUR access if needed

### Alpine Minimal
- Ultra-lightweight (~400MB)
- Fastest boot time
- Works on any x86_64 hardware
- CLI-focused recovery

---

## Common Recovery Tasks

```bash
# Mount encrypted partition
sudo cryptsetup open /dev/nvme0n1p4 pool
sudo mount /dev/mapper/pool /mnt/pool

# Fix broken bootloader
sudo grub-install --target=x86_64-efi /dev/nvme0n1
sudo grub-mkconfig -o /boot/grub/grub.cfg

# Check filesystem
sudo fsck /dev/nvme0n1p5

# Resize partition
sudo parted /dev/nvme0n1

# AI-assisted debugging
claude
```

---

## Building Notes

- **Debian**: Build on any Debian/Ubuntu system
- **Arch**: Must build on Arch Linux (requires archiso)
- **Alpine**: Build on any Linux with podman/docker

---

*Created for Surface Pro 8 - 2026*
