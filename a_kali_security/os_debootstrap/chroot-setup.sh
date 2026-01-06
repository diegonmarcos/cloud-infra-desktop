#!/bin/bash
# Kali Chroot Setup Script
# Runs inside the chroot environment

set -e

USERNAME="${1:-diego}"
PASSWORD="${2:-1234567890}"

export DEBIAN_FRONTEND=noninteractive

echo "[+] Updating package lists..."
apt-get update

echo "[+] Installing base system packages..."
apt-get install -y \
    linux-image-amd64 \
    kali-linux-core \
    systemd-sysv \
    locales \
    keyboard-configuration \
    console-setup \
    sudo \
    openssh-server \
    network-manager \
    vim \
    wget \
    curl \
    git

echo "[+] Configuring locale..."
sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/default/locale

echo "[+] Setting timezone..."
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
echo "Europe/Madrid" > /etc/timezone

echo "[+] Setting up user $USERNAME..."
if ! id "$USERNAME" &>/dev/null; then
    useradd -m -G sudo,audio,video,plugdev,netdev -s /bin/bash "$USERNAME"
fi
echo "$USERNAME:$PASSWORD" | chpasswd
echo "root:$PASSWORD" | chpasswd

# Allow sudo without password (optional, remove for security)
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USERNAME

echo "[+] Adding linux-surface repository..."
# Import GPG key
wget -qO - https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc \
    | gpg --dearmor > /etc/apt/trusted.gpg.d/linux-surface.gpg

# Add repository (using Debian release for Kali compatibility)
echo "deb [arch=amd64] https://pkg.surfacelinux.com/debian release main" \
    > /etc/apt/sources.list.d/linux-surface.list

echo "[+] Updating with linux-surface repo..."
apt-get update

echo "[+] Installing linux-surface kernel..."
apt-get install -y linux-image-surface linux-headers-surface iptsd libwacom-surface || {
    echo "[!] linux-surface install failed, trying alternative..."
    # Try with different package names
    apt-get install -y linux-surface linux-surface-headers iptsd || true
}

echo "[+] Enabling services..."
systemctl enable NetworkManager
systemctl enable ssh
systemctl enable iptsd || true

echo "[+] Configuring initramfs..."
update-initramfs -u

echo "[+] Chroot setup complete!"
