#!/bin/bash
# Chroot setup script - runs inside Arch chroot
set -e

echo "[+] Setting timezone..."
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
hwclock --systohc

echo "[+] Setting locale..."
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "[+] Setting hostname..."
echo "arch-surface" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   arch-surface.localdomain arch-surface
EOF

echo "[+] Installing essential packages..."
pacman -S --noconfirm --needed \
    networkmanager \
    openssh \
    sudo \
    vim \
    nano \
    git \
    curl \
    wget \
    cryptsetup \
    btrfs-progs \
    dosfstools \
    e2fsprogs

echo "[+] Creating user diego..."
useradd -m -G wheel,video,input -s /bin/bash diego || true
echo "diego:1234567890" | chpasswd
echo "root:1234567890" | chpasswd

echo "[+] Enabling passwordless sudo..."
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

echo "[+] Enabling services..."
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable iptsd

echo "[+] Generating initramfs..."
mkinitcpio -P

echo "[+] Chroot setup complete!"
