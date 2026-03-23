# Kali Linux + linux-surface Installation

## Overview

Install Kali Linux on Surface Pro with linux-surface kernel for keyboard/touchscreen support.

| Component | Value |
|-----------|-------|
| Target Partition | `/dev/nvme0n1p7` (25GB) |
| Method | debootstrap |
| Kernel | linux-surface (from Debian repo) |
| User | diego / 1234567890 |

## Prerequisites

- Kubuntu or other Linux running
- Internet connection
- ~30 minutes

## Quick Install

```bash
# From Kubuntu
cd /home/diego/mnt_git/unix/a_kali_security/os_debootstrap
sudo ./install-kali.sh

# After completion
sudo update-grub
sudo reboot
```

## Manual Installation

### 1. Install debootstrap

```bash
sudo apt-get update
sudo apt-get install -y debootstrap
```

### 2. Prepare Partition

```bash
sudo mkfs.ext4 -L "kali-root" /dev/nvme0n1p7
sudo mkdir -p /mnt/kali
sudo mount /dev/nvme0n1p7 /mnt/kali
```

### 3. Run Debootstrap

```bash
sudo debootstrap --arch=amd64 kali-rolling /mnt/kali http://http.kali.org/kali
```

### 4. Mount Virtual Filesystems

```bash
sudo mount -t proc none /mnt/kali/proc
sudo mount -t sysfs none /mnt/kali/sys
sudo mount --bind /dev /mnt/kali/dev
sudo mount --bind /dev/pts /mnt/kali/dev/pts
sudo cp /etc/resolv.conf /mnt/kali/etc/resolv.conf
```

### 5. Chroot and Configure

```bash
sudo chroot /mnt/kali /bin/bash
```

Inside chroot:

```bash
# Update and install base
apt-get update
apt-get install -y linux-image-amd64 kali-linux-core systemd-sysv \
    locales sudo openssh-server network-manager vim wget curl git

# Configure locale
sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen

# Add linux-surface repo
wget -qO - https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc \
    | gpg --dearmor > /etc/apt/trusted.gpg.d/linux-surface.gpg
echo "deb [arch=amd64] https://pkg.surfacelinux.com/debian release main" \
    > /etc/apt/sources.list.d/linux-surface.list

# Install linux-surface
apt-get update
apt-get install -y linux-image-surface linux-headers-surface iptsd

# Create user
useradd -m -G sudo,audio,video,plugdev,netdev -s /bin/bash diego
echo "diego:1234567890" | chpasswd
echo "root:1234567890" | chpasswd

# Enable services
systemctl enable NetworkManager ssh iptsd

# Update initramfs
update-initramfs -u

# Exit chroot
exit
```

### 6. Generate fstab

```bash
UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p7)
echo "UUID=$UUID / ext4 defaults 0 1" | sudo tee /mnt/kali/etc/fstab
```

### 7. Cleanup and Update GRUB

```bash
sudo umount -R /mnt/kali
sudo update-grub
```

### 8. Reboot

Select "Kali Linux" from GRUB menu.

## linux-surface on Kali

The [linux-surface Debian repository](https://github.com/linux-surface/linux-surface/wiki/Package-Repositories) provides:

| Package | Description |
|---------|-------------|
| `linux-image-surface` | Surface-patched kernel |
| `linux-headers-surface` | Kernel headers |
| `iptsd` | Touchscreen daemon |
| `libwacom-surface` | Wacom tablet support |

### Surface Hardware Support

| Hardware | Driver | Status |
|----------|--------|--------|
| Keyboard | surface_aggregator, surface_hid | Works |
| Touchscreen | iptsd | Works |
| WiFi | mwifiex | Works |
| Cameras | ipu3-cio2 | Partial |
| Pen | iptsd | Works |

## Troubleshooting

### Keyboard not working

```bash
# Check Surface modules
lsmod | grep surface

# If missing, load manually
sudo modprobe surface_aggregator
sudo modprobe surface_hid
```

### Touchscreen not working

```bash
# Check iptsd status
sudo systemctl status iptsd

# Restart if needed
sudo systemctl restart iptsd
```

### Boot issues

From Kubuntu:
```bash
sudo mount /dev/nvme0n1p7 /mnt/kali
sudo chroot /mnt/kali
update-initramfs -u -k all
exit
sudo update-grub
```

## Post-Install: Kali Tools

After booting into Kali:

```bash
# Install default Kali tools
sudo apt-get install -y kali-linux-default

# Or full toolset (large)
sudo apt-get install -y kali-linux-large
```

## Sources

- [linux-surface Package Repositories](https://github.com/linux-surface/linux-surface/wiki/Package-Repositories)
- [Kali Debootstrap Guide](https://www.kali.org/docs/installation/)
