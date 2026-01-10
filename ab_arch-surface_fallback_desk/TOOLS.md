# Arch Surface Fallback Desktop - Complete Tool Index

> **Total Size:** 2.3 GB
> **Partition:** nvme0n1p6 (5 GB)
> **Commands Available:** 1281
> **Updated:** 2026-01-06

---

## Quick Reference

| Task | Command |
|------|---------|
| Start GUI | `startx` |
| File manager | `nnn` |
| GUI browser | `netsurf` |
| Text browser | `lynx` |
| WiFi setup | `nmtui` |
| AI assistant | `claude` |
| Network scan | `nmap` |
| System info | `uname -a` |

---

## User Credentials

- **Username:** diego
- **Password:** 1234567890
- **Shell:** /bin/bash
- **Auto-login:** Yes (tty1)
- **Auto-startx:** Yes (openbox)

---

## Desktop Environment

| Command | Description |
|---------|-------------|
| `startx` | Start X server |
| `xinit` | X initializer |
| `openbox` | Window manager |
| `openbox-session` | Start openbox session |
| `xterm` | Terminal emulator |
| `uxterm` | Unicode xterm |
| `koi8rxterm` | KOI8-R xterm |

---

## Browsers

| Command | Description |
|---------|-------------|
| `netsurf` | Lightweight GUI browser |
| `netsurf-gtk3` | GTK3 version |
| `lynx` | Text-mode browser |

---

## File Management

| Command | Description |
|---------|-------------|
| `nnn` | Terminal file manager |
| `ls` | List files |
| `cp` | Copy files |
| `mv` | Move files |
| `rm` | Remove files |
| `mkdir` | Create directory |
| `rmdir` | Remove directory |
| `ln` | Create links |
| `find` | Find files |
| `tree` | Directory tree (if installed) |
| `stat` | File status |
| `file` | File type |
| `touch` | Create/update file |

---

## Text Editors

| Command | Description |
|---------|-------------|
| `vim` | Vi Improved |
| `vi` | → vim |
| `vimdiff` | Diff in vim |
| `vimtutor` | Vim tutorial |
| `nano` | Simple editor |
| `rnano` | Restricted nano |

---

## Network - Configuration

| Command | Description |
|---------|-------------|
| `nmtui` | NetworkManager TUI |
| `nmtui-connect` | Connect to network |
| `nmtui-edit` | Edit connections |
| `nmcli` | NetworkManager CLI |
| `nm-online` | Check connectivity |
| `networkctl` | Network status |
| `ip` | IP configuration |
| `ss` | Socket statistics |
| `ping` | Test connectivity |
| `tracepath` | Trace route |
| `resolvectl` | DNS resolver |

---

## Network - Tools

| Command | Description |
|---------|-------------|
| `nmap` | Network scanner |
| `ncat` | Netcat (nmap) |
| `nping` | Packet generator |
| `curl` | HTTP client |
| `wget` | Download files |
| `ssh` | Secure shell |
| `scp` | Secure copy |
| `sftp` | Secure FTP |
| `ssh-keygen` | Generate SSH keys |
| `ssh-copy-id` | Copy SSH key |
| `ssh-agent` | Key agent |
| `ssh-add` | Add key to agent |

---

## Network - Advanced

| Command | Description |
|---------|-------------|
| `ip` | Network config |
| `bridge` | Bridge config |
| `tc` | Traffic control |
| `iptables` | Firewall (legacy) |
| `iptables-nft` | Firewall (nftables) |
| `ip6tables` | IPv6 firewall |
| `nfnl_osf` | OS fingerprinting |
| `arping` | ARP ping |
| `arpd` | ARP daemon |

---

## Development - AI

| Command | Description |
|---------|-------------|
| `claude` | Claude Code AI assistant |

---

## Development - Node.js

| Command | Description |
|---------|-------------|
| `node` | Node.js runtime |
| `npm` | Package manager |
| `npx` | Package runner |
| `node-gyp` | Native addon build |
| `nopt` | Option parser |
| `semver` | Version parser |

---

## Development - Git

| Command | Description |
|---------|-------------|
| `git` | Version control |
| `gitk` | Git GUI |
| `git-shell` | Restricted shell |
| `git-cvsserver` | CVS emulation |
| `git-receive-pack` | Receive pack |
| `git-upload-pack` | Upload pack |
| `git-upload-archive` | Upload archive |

---

## Development - Build Tools

| Command | Description |
|---------|-------------|
| `ld` | Linker |
| `as` | Assembler |
| `ar` | Archive tool |
| `nm` | Symbol lister |
| `objdump` | Object dump |
| `objcopy` | Object copy |
| `readelf` | ELF reader |
| `strings` | String extractor |
| `strip` | Strip symbols |
| `size` | Section sizes |
| `ranlib` | Archive index |

---

## System - Process Management

| Command | Description |
|---------|-------------|
| `ps` | Process status |
| `top` | Process monitor |
| `kill` | Kill process |
| `killall` | Kill by name |
| `pkill` | Kill by pattern |
| `pgrep` | Find by pattern |
| `pidof` | Find PID |
| `nice` | Set priority |
| `renice` | Change priority |
| `nohup` | Ignore hangup |
| `timeout` | Run with timeout |

---

## System - Systemd

| Command | Description |
|---------|-------------|
| `systemctl` | Service control |
| `journalctl` | View logs |
| `hostnamectl` | Hostname |
| `timedatectl` | Time/date |
| `localectl` | Locale |
| `loginctl` | Login sessions |
| `bootctl` | Boot manager |
| `coredumpctl` | Core dumps |
| `systemd-analyze` | Boot analysis |
| `systemd-run` | Run transient |
| `systemd-escape` | Escape strings |
| `systemd-cgls` | Cgroup list |
| `systemd-cgtop` | Cgroup top |

---

## System - Hardware

| Command | Description |
|---------|-------------|
| `lspci` | List PCI |
| `lscpu` | CPU info |
| `lsblk` | Block devices |
| `lsmod` | Kernel modules |
| `lsmem` | Memory |
| `lsns` | Namespaces |
| `lsfd` | File descriptors |
| `lsipc` | IPC facilities |
| `modprobe` | Load module |
| `rmmod` | Remove module |
| `modinfo` | Module info |
| `sensors` | Hardware sensors |
| `sensors-detect` | Detect sensors |
| `hwclock` | Hardware clock |
| `rfkill` | RF kill switch |

---

## System - Disk & Filesystem

| Command | Description |
|---------|-------------|
| `fdisk` | Partition editor |
| `cfdisk` | Curses fdisk |
| `sfdisk` | Script fdisk |
| `parted` | (if installed) |
| `lsblk` | List block devices |
| `blkid` | Block device IDs |
| `mount` | Mount filesystem |
| `umount` | Unmount |
| `findmnt` | Find mounts |
| `df` | Disk free |
| `du` | Disk usage |
| `fsck` | Filesystem check |
| `mkfs.ext4` | Create ext4 |
| `mkfs.btrfs` | Create btrfs |
| `mkfs.fat` | Create FAT |
| `tune2fs` | Tune ext fs |
| `e2fsck` | Check ext fs |
| `resize2fs` | Resize ext fs |
| `btrfs` | Btrfs tool |
| `btrfsck` | Check btrfs |

---

## System - LUKS Encryption

| Command | Description |
|---------|-------------|
| `cryptsetup` | LUKS setup |
| `integritysetup` | Integrity |
| `veritysetup` | Verity |

---

## System - User Management

| Command | Description |
|---------|-------------|
| `useradd` | Add user |
| `userdel` | Delete user |
| `usermod` | Modify user |
| `passwd` | Change password |
| `chpasswd` | Batch password |
| `groupadd` | Add group |
| `groupdel` | Delete group |
| `groupmod` | Modify group |
| `groups` | Show groups |
| `id` | User/group IDs |
| `whoami` | Current user |
| `who` | Who is logged in |
| `w` | Who + what |
| `last` | Login history |
| `lastlog` | Last logins |
| `su` | Switch user |
| `sudo` | Run as root |
| `visudo` | Edit sudoers |

---

## Text Processing

| Command | Description |
|---------|-------------|
| `cat` | Concatenate |
| `head` | First lines |
| `tail` | Last lines |
| `less` | (if installed) |
| `more` | Pager |
| `grep` | Pattern search |
| `egrep` | Extended grep |
| `fgrep` | Fixed grep |
| `sed` | Stream editor |
| `awk` | Pattern processing |
| `gawk` | GNU awk |
| `cut` | Cut columns |
| `sort` | Sort lines |
| `uniq` | Unique lines |
| `wc` | Word count |
| `tr` | Translate chars |
| `diff` | Compare files |
| `comm` | Common lines |
| `paste` | Merge lines |
| `join` | Join files |
| `tee` | Pipe splitter |
| `xargs` | Build commands |

---

## Compression

| Command | Description |
|---------|-------------|
| `tar` | Archive |
| `gzip` | Gzip compress |
| `gunzip` | Gzip decompress |
| `zcat` | View gzip |
| `bzip2` | Bzip2 compress |
| `bunzip2` | Bzip2 decompress |
| `bzcat` | View bzip2 |
| `xz` | XZ compress |
| `unxz` | XZ decompress |
| `xzcat` | View xz |
| `zstd` | Zstandard |
| `unzstd` | Zstd decompress |
| `zstdcat` | View zstd |
| `lz4` | LZ4 compress |
| `unlz4` | LZ4 decompress |

---

## Arch Linux Specific

| Command | Description |
|---------|-------------|
| `pacman` | Package manager |
| `pacman-key` | Keyring |
| `pacman-conf` | Config query |
| `makepkg` | Build package |
| `yay` | AUR helper |
| `arch-chroot` | Chroot helper |
| `genfstab` | Generate fstab |
| `pacstrap` | Install to chroot |
| `mkinitcpio` | Build initramfs |
| `lsinitcpio` | List initramfs |

---

## Surface-Specific

| Command | Description |
|---------|-------------|
| `iptsd` | Touchscreen daemon |
| `iptsd-calibrate` | Calibrate touch |
| `iptsd-check-device` | Check device |
| `iptsd-dump` | Dump data |
| `iptsd-find-hidraw` | Find HID device |

---

## Graphics / OpenGL

| Command | Description |
|---------|-------------|
| `glxinfo` | OpenGL info |
| `glxgears` | OpenGL test |
| `eglinfo` | EGL info |
| `eglgears_x11` | EGL test |
| `vkgears` | Vulkan test |
| `Xorg` | X server |
| `xauth` | X authority |
| `xrdb` | X resources |
| `xmodmap` | Key mapping |
| `xprop` | Window properties |
| `setxkbmap` | Keyboard layout |

---

## Utilities

| Command | Description |
|---------|-------------|
| `date` | Date/time |
| `cal` | Calendar |
| `uptime` | System uptime |
| `uname` | System info |
| `hostname` | Hostname |
| `env` | Environment |
| `printenv` | Print env |
| `export` | Set env |
| `alias` | Create alias |
| `which` | Find command |
| `whereis` | Find binary |
| `type` | Command type |
| `echo` | Print text |
| `printf` | Format print |
| `yes` | Repeat string |
| `true` | Return true |
| `false` | Return false |
| `sleep` | Delay |
| `watch` | Repeat command |
| `time` | Time command |

---

## Security / Crypto

| Command | Description |
|---------|-------------|
| `gpg` | GnuPG |
| `gpg2` | GnuPG 2 |
| `gpg-agent` | Key agent |
| `openssl` | SSL toolkit |
| `ssh-keygen` | SSH keys |
| `certutil` | NSS certs |
| `p11-kit` | PKCS#11 |
| `trust` | Trust anchors |

---

## Package Sizes (Explicitly Installed)

| Package | Size | Category |
|---------|------|----------|
| linux-surface | 115 MB | OS |
| claude-code | 214 MB | Dev |
| nodejs | 61 MB | Dev |
| git | 30 MB | Dev |
| nmap | 26 MB | Network |
| networkmanager | 15 MB | Network |
| yay | 9 MB | Arch |
| sudo | 8 MB | System |
| iptsd | 8 MB | Surface |
| npm | 7 MB | Dev |
| btrfs-progs | 7 MB | Disk |
| openssh | 6 MB | Network |
| wget | 6 MB | Network |
| vim | 5 MB | Editor |
| lynx | 5 MB | Browser |
| netsurf | 5 MB | Browser |
| xorg-server | 4 MB | Desktop |
| nano | 3 MB | Editor |
| openbox | 1 MB | Desktop |
| xterm | 1 MB | Desktop |
| nnn | 364 KB | Files |

---

## Disk Usage

```
OS (kernel, firmware, libs)    1.4 GB
Tools                          0.6 GB
Bloat (man, docs)              0.3 GB
────────────────────────────────────────
Total                          2.3 GB
Free                           2.6 GB
```
