# Alpine Recovery - OS Installation Config

> Pre-boot configurations applied during installation
> Date: 2026-01-06
> Source: Kubuntu Live

---

## Partition

| Property | Value |
|----------|-------|
| Device | `/dev/nvme0n1p6` |
| Label | `alpine` |
| Size | 5 GB |
| Filesystem | ext4 |
| UUID | `1b83a136-cf05-47af-aa32-d912d471b757` |

---

## Hostname

```
/etc/hostname: alpine-recovery
```

---

## Timezone

```
/etc/localtime -> /usr/share/zoneinfo/Europe/Madrid
```

---

## Filesystem Table

```
# /etc/fstab

# Alpine Root
UUID=1b83a136-cf05-47af-aa32-d912d471b757    /            ext4    defaults,noatime    0 1

# EFI
UUID=2CE0-6722       /boot/efi    vfat    defaults,umask=0077 0 2

# Shared Boot
UUID=0eaf7961-48c5-4b55-8a8f-04cd0b71de07    /boot        ext4    defaults,noatime    0 2

# Kubuntu mount
UUID=7e3626ac-ce13-4adc-84e2-1a843d7e2793    /mnt/kubuntu ext4    defaults,noauto     0 0
```

---

## Users

### root
| Property | Value |
|----------|-------|
| UID | 0 |
| Shell | `/bin/sh` |
| Password | `1234567890` |

### diego
| Property | Value |
|----------|-------|
| UID | 1000 |
| Shell | `/bin/bash` |
| Password | `1234567890` |
| Groups | `diego`, `wheel` |

---

## Sudo Configuration

```
# /etc/sudoers.d/wheel
%wheel ALL=(ALL) NOPASSWD: ALL
```

---

## Services Enabled

| Service | Runlevel | Purpose |
|---------|----------|---------|
| `dbus` | default | Message bus |
| `networkmanager` | default | Network management |
| `sshd` | default | SSH server |

---

## APK Packages Installed (248)

### Base System
- `alpine-base`, `linux-lts`, `openrc`

### Shells
- `bash`, `zsh`, `fish`

### Editors
- `vim`, `nano`

### Networking
- `networkmanager`, `networkmanager-wifi`, `wpa_supplicant`
- `openssh`, `curl`, `wget`, `git`

### Graphics
- `xorg-server`, `xinit`, `openbox`, `xterm`
- `mesa-dri-gallium`, `ttf-dejavu`

### Browsers
- `dillo`, `links`

### Monitors
- `btop`, `htop`

### Development
- `nodejs` (v22), `npm`
- `python3`, `py3-pip`

### Utilities
- `util-linux`, `e2fsprogs`, `dosfstools`
- `grub`, `grub-efi`, `sudo`, `jq`

---

## Boot Configuration

### Kernel Files in /boot
```
/boot/vmlinuz-alpine      # Linux kernel
/boot/initramfs-alpine    # Initial ramdisk
```

### GRUB Entry
```
# /boot/grub/custom.cfg

menuentry 'Alpine Linux (Recovery)' --class alpine --class gnu-linux {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root 0eaf7961-48c5-4b55-8a8f-04cd0b71de07
    linux /vmlinuz-alpine root=UUID=1b83a136-cf05-47af-aa32-d912d471b757 rw modules=sd-mod,usb-storage,ext4 quiet
    initrd /initramfs-alpine
}
```

---

## Mount Points Created

| Path | Purpose |
|------|---------|
| `/mnt/kubuntu` | Mount Kubuntu partition |
| `/boot` | Shared boot partition |
| `/boot/efi` | EFI system partition |

---

## Home Directory Setup

```
/home/diego/
├── install.json      # Package configuration database
├── install.sh        # Post-boot setup script
├── install.md        # User documentation
├── install_log.md    # Session logs
├── install_os.md     # This file
└── .xsession         # X session config
```

---

## Network Configuration

- **Method**: NetworkManager
- **WiFi**: Via `nmtui` or `nmcli`
- **Config**: `/etc/NetworkManager/`

---

## Installation Method

1. Mounted Alpine ISO
2. Used `apk.static` to bootstrap
3. Installed packages via `apk`
4. Configured files via chroot
5. Copied kernel to shared /boot
6. Added GRUB entry

---

*Generated during Alpine Recovery installation*
