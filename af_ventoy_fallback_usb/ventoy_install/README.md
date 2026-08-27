# Ventoy Fallback USB Setup

> Multi-boot USB with live OS images that load entirely to RAM

---

## USB Layout After Setup

```
/dev/sda (28.9GB USB)
├── Partition 1: Ventoy (exFAT/NTFS) ~27GB - ISO storage
└── Partition 2: VTOYEFI (FAT) ~32MB - EFI boot
```

---

## Included Live Images

| OS | Size | Purpose | Surface Support |
|----|------|---------|-----------------|
| Debian Slim Surface | ~800MB | Full recovery with GUI | linux-surface kernel |
| Arch Surface | ~1.2GB | Desktop-ready recovery | linux-surface kernel |
| Alpine Minimal | ~400MB | Ultra-light CLI recovery | Generic kernel |

---

## Installation Steps

### 1. Install Ventoy

```bash
# Download latest Ventoy
wget https://github.com/ventoy/Ventoy/releases/download/v1.0.99/ventoy-1.0.99-linux.tar.gz
tar xzf ventoy-1.0.99-linux.tar.gz
cd ventoy-1.0.99

# Install to USB (WARNING: this erases the drive!)
sudo ./Ventoy2Disk.sh -i /dev/sda

# Or update existing Ventoy:
sudo ./Ventoy2Disk.sh -u /dev/sda
```

### 2. Copy Configuration

```bash
# Mount Ventoy partition
sudo mount /dev/sda1 /mnt

# Copy ventoy config
sudo cp -r ventoy/ /mnt/

# Copy ISO images
sudo cp *.iso /mnt/

sudo umount /mnt
```

### 3. Build Live ISOs

```bash
# Build Debian Surface Live
./build_debian_live.sh

# Build Arch Surface Live
./build_arch_live.sh

# Build Alpine Live
./build_alpine_live.sh
```

---

## Ventoy Config Structure

```
/mnt/                          # Ventoy partition (sda1)
├── ventoy/
│   ├── ventoy.json           # Boot menu config
│   └── ventoy_grub.cfg       # Custom GRUB config
├── debian-surface-live.iso   # Debian + Surface (toram)
├── arch-surface-live.iso     # Arch + Surface (toram)
└── alpine-live.iso           # Alpine minimal
```

---

## ventoy.json Options

Key settings for Surface Pro:
- `VTOY_DEFAULT_MENU_MODE=1` - Show menu by default
- `VTOY_LINUX_REMOUNT=1` - Remount ISO after boot
- `VTOY_FILT_DOT_UNDERSCORE_FILE=1` - Filter macOS files

TORAM settings:
- Custom GRUB entries with `toram` parameter
- Loads entire ISO to RAM for speed

---

## Surface Pro Notes

1. **Secure Boot**: Must be disabled in UEFI
2. **Boot Order**: USB should be first
3. **Keyboard**: Works after linux-surface kernel loads
4. **WiFi**: Works with linux-surface firmware

---

## Files in This Directory

| File | Description |
|------|-------------|
| `ventoy.json` | Main Ventoy configuration |
| `ventoy_grub.cfg` | Custom GRUB menu entries |
| `build_debian_live.sh` | Build Debian Surface Live ISO |
| `build_arch_live.sh` | Build Arch Surface Live ISO |
| `build_alpine_live.sh` | Build Alpine minimal ISO |
| `install_ventoy.sh` | Automated Ventoy installer |

---

*For Surface Pro 8 - Ventoy 1.0.99+*
