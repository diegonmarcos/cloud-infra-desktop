# Kali Linux Surface - Quick Install Guide

## Quick Start

```bash
# Extract
tar xf install.tar

# 1. Verify Surface drivers
./install.sh surface

# 2. Scan for missing packages
./install.sh scan

# 3. Install base packages
./install.sh install

# 4. Install Kali security tools
./install.sh kali

# 5. Start desktop
./install.sh desktop
```

## Commands

| Command | Description |
|---------|-------------|
| `surface` | Verify/install linux-surface drivers |
| `scan` | Check installed vs missing packages |
| `install` | Install base packages (shells, editors, dev tools) |
| `kali` | Install Kali security tools (nmap, metasploit, etc.) |
| `desktop` | Start Openbox (X11) |
| `sway` | Start Sway (Wayland) |

## Package Categories

### Base System
- shells: bash, zsh, fish
- editors: vim, nano, neovim
- network: network-manager, openssh-server, curl, wget, git

### Desktop
- graphics: xorg, openbox, xterm, mesa-utils
- wayland: sway, foot, wofi

### Development
- dev: nodejs, npm, python3, python3-pip
- cli_tools: ripgrep, fd-find, fzf, jq, tmux, eza, bat

### Kali Security Tools
- Scanning: nmap, tcpdump, wireshark
- Exploitation: metasploit-framework, sqlmap
- Cracking: john, hashcat, hydra
- Wireless: aircrack-ng
- Web: burpsuite

## Files

| File | Description |
|------|-------------|
| `install.sh` | Main setup script |
| `install.json` | Package definitions |
| `install.md` | This file |
| `install_log.md` | Installation log (created on run) |
| `install_check.md` | Scan results (created on run) |

## Surface Hardware

linux-surface provides:
- `surface_aggregator` - Hardware communication bus
- `surface_hid` - Keyboard/trackpad support
- `iptsd` - Touchscreen/pen support

Check status:
```bash
lsmod | grep surface
systemctl status iptsd
```

## Notes

- Uses `apt` package manager (Debian/Kali)
- linux-surface repo: `https://pkg.surfacelinux.com/debian`
- Default user: diego / 1234567890
