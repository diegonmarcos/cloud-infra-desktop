# Debian Rescue OS — Tools Reference

> **Hostname**: rescue-os-debian
> **Partition**: `/dev/nvme0n1p6` (5GB ext4, label `debian`)
> **Bootloader**: rEFInd (kernel at `/EFI/debian/` on ESP)
> **Default user**: `diego` / `1234567890` (fish shell, NOPASSWD sudo)
> **Purpose**: Minimal CLI rescue OS for the Surface Pro 8. Boot it when NixOS or Kali is broken; use Node + Claude Code to fix things.

---

## What's Installed

### Shells
| Tool | Purpose |
|---|---|
| `fish` | Default login shell for `diego`. Friendly autocomplete. |
| `bash` | Fallback / `/bin/sh`. |
| `bash-completion` | tab-complete for bash. |

### Editors
`vim`, `nano`

### Network
| Tool | Purpose |
|---|---|
| `NetworkManager` (`nmcli`, `nmtui`) | **Primary** network manager (enabled). |
| `systemd-networkd` | Installed but masked. Enable manually if NM fails: `sudo systemctl unmask systemd-networkd && sudo systemctl enable --now systemd-networkd && sudo systemctl disable --now NetworkManager`. |
| `systemd-resolved` | DNS resolver (enabled). |
| `openssh-server` | Inbound SSH (enabled — `ssh diego@<ip>`). |
| `wpasupplicant`, `iw`, `rfkill` | WiFi backends. |
| `iproute2`, `iputils-ping`, `dnsutils` | `ip`, `ping`, `dig`, `nslookup`. |

### Browser stack (for Claude OAuth)
| Tool | Launcher |
|---|---|
| `firefox-esr` | One-shot: `./install.sh browser` (= `startx /usr/bin/firefox-esr`) |
| `i3` + `i3status` + `dmenu` | Full X session: `./install.sh session` |
| `cage` | Wayland kiosk: `./install.sh kiosk` |
| `w3m` | Text browser fallback (no JS — won't pass OAuth fingerprint checks). |

### CLI tools
`ripgrep` (`rg`), `fd-find` (`fd`), `fzf`, `jq`, `tmux`, `eza`, `bat`, `htop`, `btop`, `iotop`, `lsof`, `tree`, `file`, `neofetch`

### Files / archives
`rsync`, `tar`, `gzip`, `xz-utils`, `zip`, `unzip`

### Filesystem / recovery
`cryptsetup`, `btrfs-progs`, `dosfstools`, `e2fsprogs`, `ntfs-3g`, `efibootmgr`

### Development
`git`, `build-essential`, `pkg-config`, `make`, `python3`, `python3-pip`, `python3-venv`

### Node.js + Claude Code
| Tool | Notes |
|---|---|
| `nodejs` (Node.js 22 LTS via NodeSource) | `node`, `npm`, `npx` |
| `@anthropic-ai/claude-code` (npm global) | Run with `claude` |

---

## Common Tasks

### Connect WiFi
```bash
nmtui                                              # TUI
nmcli device wifi list
nmcli device wifi connect <SSID> password <PASS>
```

### Launch Claude Code (with browser-based auth)
```bash
./install.sh browser    # opens Firefox standalone — log into claude.ai there
# (close browser when done)
claude                  # or: ./install.sh claude
```

If you have an API key and want to skip browser entirely:
```fish
set -Ux ANTHROPIC_API_KEY sk-ant-...
claude
```

### Mount partitions on demand
```bash
./install.sh mount-all       # mounts ESP, /boot, /mnt/kubuntu, /mnt/kali (skips encrypted)
./install.sh mount-pool      # unlocks LUKS, mounts /mnt/pool
```

Or individually:
```bash
sudo mount /mnt/efi          # ESP                      (p1)
sudo mount /mnt/boot         # shared /boot             (p3)
sudo mount /mnt/kubuntu      # Kubuntu root             (p5)
sudo mount /mnt/kali         # Kali root                (p7)

# LUKS pool (p4):
sudo cryptsetup open /dev/nvme0n1p4 pool
sudo mount /mnt/pool                                     # btrfs root
# or specific subvolumes:
sudo mount -o subvol=@home-diego /dev/mapper/pool /mnt/pool-home
sudo mount -o subvol=@nixos     /dev/mapper/pool /mnt/pool-nixos
sudo mount -o subvol=@shared    /dev/mapper/pool /mnt/pool-shared
```

### Get into NixOS to fix it
```bash
./install.sh mount-pool
# Then chroot in (mirrors @home-diego/git/unix/rescue-chroot-nixos.sh):
sudo /mnt/pool/@home-diego/git/unix/rescue-chroot-nixos.sh
```

### Verify everything is installed
```bash
./install.sh scan            # generates install_check.md
```

### Re-install missing packages
```bash
./install.sh install         # idempotent
```

---

## File Layout

| Path | What |
|---|---|
| `/etc/quickref` | The login banner (cat'd by bash + fish on every shell). |
| `/etc/profile.d/zz-quickref.sh` | bash login → cats `/etc/quickref`. |
| `/etc/fish/conf.d/quickref.fish` | fish `fish_greeting` → cats `/etc/quickref`. |
| `~/README.md` | This file. |
| `~/git/unix/rescue-os-debian/` | The install scripts (copied here during bootstrap so they work without the pool unlocked). |
| `~/git/unix/...` (full tree) | Available once you `./install.sh mount-pool`. |

---

## Bootloader (rEFInd)

The Debian kernel + initrd stay on **p6** (this filesystem). rEFInd reads p6 directly via its built-in ext4 driver — the ESP (100 MB total) is too small to hold every distro's kernel+initrd.

The menuentry in `/mnt/efi/EFI/refind/refind.conf`:

```
menuentry "Debian Rescue OS" {
    icon     /EFI/refind/icons/os_debian.png
    volume   debian              # filesystem label = p6
    loader   /vmlinuz            # symlink → /boot/vmlinuz-X.Y (latest)
    initrd   /initrd.img         # symlink → /boot/initrd.img-X.Y (latest)
    options  "root=UUID=<p6-uuid> rw quiet"
}
```

**Kernel updates auto-track:** Debian maintains `/vmlinuz` and `/initrd.img` symlinks at the filesystem root, pointing at the latest installed kernel. `apt upgrade` updates the symlinks automatically — no manual ESP copy needed. Reboot picks up the new kernel.

Verify after an upgrade:
```bash
ls -la /vmlinuz /initrd.img
# /vmlinuz -> boot/vmlinuz-6.12.85+deb13-amd64
```

---

## Troubleshooting

### Firefox won't start
```bash
# Check X works at all:
startx /usr/bin/xterm
# If xterm opens, X is fine — investigate firefox-esr.
# If xterm fails, check Xorg log: cat /var/log/Xorg.0.log | tail -30
```

### Claude OAuth fails (fingerprint check)
- Make sure you're using `firefox-esr`, not a text browser.
- `./install.sh browser` runs Firefox standalone, which is what OAuth providers expect.
- Alternative: log into claude.ai on your phone, copy the auth token to `~/.claude/`.

### LUKS pool won't unlock
```bash
# Verify the device:
sudo cryptsetup luksDump /dev/nvme0n1p4
# Confirm UUID matches: 3c75c6db-4d7c-4570-81f1-02d168781aac
# If passphrase forgotten — recover from another distro using a backup key.
```

### Kernel update broke boot
1. From rEFInd, boot any other distro.
2. Mount p6: `sudo mount /dev/nvme0n1p6 /mnt/p6`
3. Mount ESP: `sudo mount /dev/nvme0n1p1 /mnt/efi`
4. Recopy kernel: `sudo cp /mnt/p6/boot/vmlinuz-* /mnt/efi/EFI/debian/vmlinuz`
5. Same for initrd.

---

## Files in This Setup Dir

| File | Purpose |
|---|---|
| `install.json` | Declarative spec — packages, services, mounts. |
| `install.sh` | Post-boot configurator (`scan`, `install`, `browser`, `claude`, `mount-pool`, …). |
| `install.md` | High-level installation guide (this file is the tools reference). |
| `SETUP.md` | Step-by-step setup walkthrough. |
| `TOOLS.md` | This file — tool reference. |
| `install_log.md` | Append-only log of installs/runs. |
| `bootstrap/install-debian.sh` | The from-Kali bootstrapper (mkfs + debootstrap + chroot + rEFInd). |
| `bootstrap/chroot-setup.sh` | Runs inside the chroot — kernel, packages, user, services. |
| `bootstrap/apt-sources.list` | Debian apt sources. |
