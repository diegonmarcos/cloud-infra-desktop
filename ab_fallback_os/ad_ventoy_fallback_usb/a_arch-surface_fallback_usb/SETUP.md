# Arch Linux + Surface Drivers - Fallback Desktop

> **Purpose**: Minimal fallback OS with Surface Pro keyboard/touchscreen support
> **Partition**: nvme0n1p6 (5GB)
> **Use case**: Recovery, escape route, secondary desktop

---

## Why Arch + linux-surface?

- **Minimal**: ~800MB base install
- **Surface keyboard WORKS**: Official linux-surface repo
- **Rolling release**: Always current
- **Can unlock LUKS**: cryptsetup available

---

## Prerequisites

- Bootable USB with Arch ISO (or Ventoy)
- Internet connection (WiFi or ethernet)
- USB keyboard (Surface keyboard won't work during install until drivers installed)

---

## Installation Steps

### Step 1: Boot Arch ISO from USB

```bash
# From Ventoy or direct USB boot
# Use USB keyboard initially
```

### Step 2: Connect to Internet

```bash
# WiFi
iwctl
station wlan0 scan
station wlan0 get-networks
station wlan0 connect "SSID"
exit

# Or ethernet (automatic)
```

### Step 3: Partition Already Ready

```bash
# nvme0n1p6 is already 5GB ext4, formatted
# Just mount it
mount /dev/nvme0n1p6 /mnt
```

### Step 4: Install Base System

```bash
# Update mirrors (optional, for speed)
reflector --country Spain,France,Germany --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# Install base + essentials
pacstrap -K /mnt base linux linux-firmware \
    networkmanager vim nano sudo \
    cryptsetup btrfs-progs \
    openssh curl wget git

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab
```

### Step 5: Chroot and Configure

```bash
arch-chroot /mnt

# Timezone
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
hwclock --systohc

# Locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "arch-surface" > /etc/hostname

# Root password
passwd
# Set: 1234567890

# Create user
useradd -m -G wheel -s /bin/bash user
passwd user
# Set: 1234567890

# Sudo without password
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
```

### Step 6: Install linux-surface

```bash
# Add linux-surface repo to /etc/pacman.conf
cat >> /etc/pacman.conf << 'EOF'

[linux-surface]
Server = https://pkg.surfacelinux.com/arch/
EOF

# Import keys
pacman-key --recv-keys 56C464BAAC421453
pacman-key --lsign-key 56C464BAAC421453

# Update and install Surface kernel
pacman -Syu
pacman -S linux-surface linux-surface-headers iptsd

# Enable iptsd (touchscreen)
systemctl enable iptsd
```

### Step 7: Bootloader (systemd-boot)

```bash
# Install bootloader
bootctl install

# Create loader config
cat > /boot/loader/loader.conf << 'EOF'
default arch-surface.conf
timeout 3
console-mode max
editor no
EOF

# Create boot entry
cat > /boot/loader/entries/arch-surface.conf << 'EOF'
title   Arch Linux Surface
linux   /vmlinuz-linux-surface
initrd  /initramfs-linux-surface.img
options root=UUID=1b83a136-cf05-47af-aa32-d912d471b757 rw
EOF

# Note: UUID is for nvme0n1p6 (alpine/arch partition)
```

### Step 8: Enable Services

```bash
# Network
systemctl enable NetworkManager

# SSH
systemctl enable sshd

# Exit and reboot
exit
umount -R /mnt
reboot
```

---

## Post-Install (After First Boot)

### Install Node.js + Claude CLI

```bash
# Node.js
sudo pacman -S nodejs npm

# Claude Code CLI
sudo npm install -g @anthropic-ai/claude-code

# Set API key
echo 'export ANTHROPIC_API_KEY="sk-ant-..."' >> ~/.bashrc
source ~/.bashrc

# Test
claude --version
```

### Install Desktop (Optional - Minimal)

```bash
# Minimal X11 + Openbox (very light)
sudo pacman -S xorg-server xorg-xinit openbox xterm

# Or minimal Wayland + Sway
sudo pacman -S sway foot wofi

# Start manually
# X11: startx
# Wayland: sway
```

### Test LUKS Unlock

```bash
# Verify can unlock NixOS LUKS partition
sudo cryptsetup open /dev/nvme0n1p4 pool
sudo mount /dev/mapper/pool /mnt -o subvol=@root-nixos
ls /mnt
sudo umount /mnt
sudo cryptsetup close pool
```

---

## Verification Checklist

- [ ] Boots from GRUB/systemd-boot menu
- [ ] Surface keyboard works
- [ ] Surface touchscreen works
- [ ] WiFi connects
- [ ] Can SSH in
- [ ] Can unlock LUKS partition
- [ ] Node.js + Claude CLI work

---

## Recovery Commands

```bash
# From Arch, unlock and mount NixOS:
sudo cryptsetup open /dev/nvme0n1p4 pool
sudo mount /dev/mapper/pool /mnt -o subvol=@root-nixos

# Access NixOS files
ls /mnt/etc/nixos/

# Chroot into NixOS (if needed)
sudo arch-chroot /mnt
```

---

## Disk Layout Reference

```
nvme0n1p1   100M   EFI         /boot/efi
nvme0n1p2    16M   (reserved)
nvme0n1p3     2G   ext4        /boot
nvme0n1p4    80G   LUKS→BTRFS  (NixOS)
nvme0n1p5   118G   ext4        (Kubuntu - to be deleted)
nvme0n1p6     5G   ext4        ← ARCH LINUX HERE
nvme0n1p7    25G   ext4        (Kali)
```
