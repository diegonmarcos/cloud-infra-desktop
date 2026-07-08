# NixOS Surface Slim

Minimal NixOS USB recovery system for Surface Pro 8.

## Features

- **Surface Hardware Support**: linux-surface kernel, iptsd (Type Cover keyboard)
- **Minimal GUI**: SDDM + Openbox
- **CLI Tools**: fish, vim, btop, ripgrep, fzf, tmux, etc.
- **Claude Code**: Node.js + npm for AI-assisted recovery
- **Disk Tools**: btrfs, cryptsetup, parted for LUKS/btrfs recovery
- **WiFi**: NetworkManager + iwd backend

## Credentials

| User | Password |
|------|----------|
| diego | 1234567890 |
| root | 1234567890 |

## Build

```bash
# Build ISO
./build.sh

# Build VM for testing
./build.sh vm

# Check flake syntax
./build.sh check
```

## Usage

1. Copy ISO to Ventoy USB:
   ```bash
   cp nixos-surface-slim.iso /path/to/ventoy/
   ```

2. Boot from USB, select "NixOS Surface"

3. Login as `diego` (auto-login enabled)

4. GUI starts automatically (SDDM -> Openbox)

## Keyboard Shortcuts (Openbox)

| Shortcut | Action |
|----------|--------|
| Super+Return | Terminal (sakura) |
| Super+E | File manager (pcmanfm) |
| Super+B | Browser (surf) |
| Super+D | Launcher (rofi) |
| Super+Q | Close window |
| Alt+Tab | Switch windows |
| Right-click | Menu |

## Commands

```bash
# WiFi
nmtui              # TUI WiFi config
nmcli dev wifi     # List networks
nmcli dev wifi connect "SSID" password "pass"

# Claude Code
claude             # Start Claude Code CLI

# System
btop               # System monitor
neofetch           # System info

# Disk recovery
sudo cryptsetup open /dev/nvme0n1pX pool   # Unlock LUKS
sudo mount /dev/mapper/pool /mnt/pool      # Mount btrfs
sudo btrfs subvolume list /mnt/pool        # List subvolumes
```

## Surface-Specific Notes

### Type Cover Keyboard
- The `iptsd` service handles Type Cover input
- If keyboard doesn't work, check: `systemctl status iptsd`
- Restart if needed: `sudo systemctl restart iptsd`

### Touchscreen
- Works via `hid_multitouch` module
- Touch works in SDDM and Openbox

### WiFi
- Uses `iwd` backend for better Surface support
- NetworkManager handles connection management

## File Structure

```
nixos-surface-slim/
├── flake.nix           # Nix flake definition
├── configuration.nix   # Main system configuration
├── iso.nix             # ISO-specific settings
├── build.sh            # Build script
├── install.json        # Package manifest
└── README.md           # This file
```

## Estimated Size

~700-900MB ISO (comparable to Arch/Debian slim builds)

## Troubleshooting

### No keyboard after boot
```bash
# Use touchscreen or USB keyboard to run:
sudo systemctl restart iptsd
```

### No WiFi
```bash
# Check if iwd is running
systemctl status iwd

# Restart NetworkManager
sudo systemctl restart NetworkManager

# Manual WiFi connect
nmcli dev wifi list
nmcli dev wifi connect "SSID" password "password"
```

### Display issues
```bash
# Check Xorg logs
cat ~/.local/share/xorg/Xorg.0.log | tail -50

# Restart SDDM
sudo systemctl restart sddm
```
