# Debian Surface Live ISO

> Lightweight live USB recovery system with Surface Pro 8 support

---

## Quick Reference

| Item | Value |
|------|-------|
| **ISO** | `debian-surface-live.iso` (~676 MB) |
| **Kernel** | 6.18.2-surface-1 |
| **Base** | Debian 12 (Bookworm) |
| **GUI** | Openbox + sakura + pcmanfm |
| **RAM (toram)** | ~3.2 GB free |

### Credentials

| User | Password |
|------|----------|
| `diego` | `1234567890` |
| `root` | `1234567890` |

---

## Boot Options

From Ventoy or GRUB menu:

| Option | Description |
|--------|-------------|
| **Load to RAM** | Copies ISO to RAM, USB can be removed |
| **Normal Boot** | Runs from USB, must stay plugged in |
| **Debug** | Verbose boot for troubleshooting |

---

## After Boot

System auto-logins to `diego` with fish shell.

```bash
# Start GUI
startx

# Or use CLI tools directly
nmtui          # WiFi setup
claude         # Claude Code AI
btop           # System monitor
```

---

## Openbox GUI

### Right-Click Menu

- **Terminal** - sakura
- **Files** - pcmanfm
- **WiFi (nmtui)** - Network setup
- **Claude Code** - AI assistant
- **System Monitor** - btop
- **Reboot / Shutdown**

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Super+Return` | Terminal |
| `Super+E` | File manager |
| `Super+Q` | Close window |
| `Alt+F4` | Close window |
| `Alt+Tab` | Switch windows |

---

## Recovery Tasks

```bash
# Mount encrypted partition
sudo cryptsetup open /dev/nvme0n1p4 pool
sudo mount /dev/mapper/pool /mnt/pool

# Fix bootloader
sudo grub-install --target=x86_64-efi /dev/nvme0n1
sudo grub-mkconfig -o /boot/grub/grub.cfg

# Check filesystem
sudo fsck /dev/nvme0n1p5

# Partition management
sudo parted /dev/nvme0n1
```

---

## Build the ISO

```bash
# Requires Debian/Ubuntu host
sudo ./build_live.sh

# Output: debian-surface-live.iso
```

---

## Copy to Ventoy USB

```bash
sudo mount /dev/sda1 /mnt
sudo cp debian-surface-live.iso /mnt/
sudo umount /mnt
```

---

## Files

| File | Description |
|------|-------------|
| `build_live.sh` | ISO build script |
| `install.json` | Package/config manifest |
| `README.md` | This file |

---

## Surface Pro 8 Support

| Feature | Status |
|---------|--------|
| Keyboard | Works (linux-surface) |
| Touchscreen | Works (iptsd) |
| WiFi | Works (linux-surface firmware) |
| Display | Works (mesa) |

**Note**: Secure Boot must be **disabled** in UEFI settings.

---

*Built for Surface Pro 8 - 2026*
