#!/bin/bash
# Chroot setup script - runs inside Debian chroot during bootstrap
# Installs kernel + base packages + browser stack + node + claude-code,
# configures user, locale, timezone, hostname, services, fish + bash greetings.
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
section() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }

# Disable service starts during install (debian convention)
cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

section "Updating apt indexes"
apt-get update -qq

section "Setting timezone (Europe/Madrid)"
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
echo "Europe/Madrid" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

section "Setting locale (en_US.UTF-8)"
sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

section "Setting hostname (rescue-os-debian)"
echo "rescue-os-debian" > /etc/hostname
cat > /etc/hosts << 'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   rescue-os-debian.localdomain rescue-os-debian
EOF

section "Adding linux-surface apt repo"
apt-get install -y --no-install-recommends curl gnupg
curl -fsSL https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc | \
    gpg --dearmor -o /etc/apt/trusted.gpg.d/linux-surface.gpg
echo "deb [arch=amd64] https://pkg.surfacelinux.com/debian release main" \
    > /etc/apt/sources.list.d/linux-surface.list
apt-get update -qq

section "Installing kernel + firmware (Surface)"
apt-get install -y --no-install-recommends \
    linux-image-surface linux-headers-surface \
    iptsd libwacom-surface \
    firmware-linux-free firmware-linux-nonfree firmware-iwlwifi firmware-misc-nonfree \
    intel-microcode \
    initramfs-tools

section "Installing base CLI"
apt-get install -y --no-install-recommends \
    console-setup keyboard-configuration \
    bash bash-completion fish \
    vim nano less \
    man-db manpages \
    sudo \
    git curl wget ca-certificates gnupg \
    rsync tar gzip xz-utils zip unzip \
    htop btop tmux tree file lsof \
    ripgrep fd-find fzf jq eza bat \
    python3 python3-pip python3-venv \
    build-essential pkg-config make \
    dosfstools e2fsprogs cryptsetup btrfs-progs ntfs-3g \
    efibootmgr

section "Installing networking"
# Note: systemd-networkd is part of the 'systemd' package in trixie — no
# separate apt package. Enable on demand: systemctl enable systemd-networkd.
apt-get install -y --no-install-recommends \
    network-manager network-manager-openvpn \
    systemd-resolved \
    iproute2 iputils-ping dnsutils \
    openssh-client openssh-server \
    wpasupplicant iw rfkill

section "Installing X11 + i3 + Firefox + cage (browser stack for Claude OAuth)"
apt-get install -y --no-install-recommends \
    xserver-xorg-core \
    xserver-xorg-input-libinput xserver-xorg-input-evdev \
    xserver-xorg-video-fbdev xserver-xorg-video-intel \
    xinit xterm \
    i3 i3status dmenu \
    cage foot \
    firefox-esr w3m

section "Installing Node.js LTS via NodeSource"
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
    gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
apt-get update -qq
apt-get install -y --no-install-recommends nodejs

section "Installing @anthropic-ai/claude-code globally"
npm install -g @anthropic-ai/claude-code || warn "claude-code install failed (offline?) — install later via install.sh"

section "Creating user diego (UID 1000, fish shell, sudo NOPASSWD)"
if ! id diego >/dev/null 2>&1; then
    useradd -m -u 1000 -G sudo,video,input,netdev,plugdev -s /usr/bin/fish diego
fi
echo "diego:1234567890" | chpasswd
echo "root:1234567890" | chpasswd
mkdir -p /etc/sudoers.d
cat > /etc/sudoers.d/90-diego <<'EOF'
diego ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 440 /etc/sudoers.d/90-diego

section "Creating mount points"
mkdir -p /mnt/efi /mnt/boot /mnt/pool /mnt/shared-lib /mnt/kali

section "Enabling services"
systemctl enable NetworkManager
systemctl enable ssh
systemctl enable systemd-resolved
# systemd-networkd installed but NOT enabled (NetworkManager owns interfaces)
systemctl mask systemd-networkd 2>/dev/null || true

section "Writing /etc/quickref (local rescue cheatsheet)"
cat > /etc/quickref <<'EOF'
─── debian rescue-os-debian — quick reference ───────────────
BROWSER (for Claude OAuth or web tasks):
  startx /usr/bin/firefox-esr     # one-shot Firefox, no WM
  startx /usr/bin/i3              # full i3 tiling session
  cage -- firefox-esr             # Wayland kiosk

CLAUDE CODE:
  claude                          # OAuth → opens Firefox
  set -Ux ANTHROPIC_API_KEY ...   # alternative: API key (no browser)

MOUNTS (all noauto — mount on demand):
  sudo mount /mnt/efi             # EFI System Partition (p1)
  sudo mount /mnt/boot            # shared /boot         (p3)
  sudo mount /mnt/shared-lib      # Shared-Lib (Docker)  (p5)
  sudo mount /mnt/kali            # Kali root            (p7)

LUKS POOL (p4) — encrypted, unlock + mount manually:
  sudo cryptsetup open /dev/nvme0n1p4 pool
  sudo mount /mnt/pool                                 # btrfs
  sudo mount -o subvol=@home-diego /dev/mapper/pool /mnt/pool-home
  sudo mount -o subvol=@nixos     /dev/mapper/pool /mnt/pool-nixos
  sudo mount -o subvol=@shared    /dev/mapper/pool /mnt/pool-shared

NETWORK:
  nmtui                           # NetworkManager TUI
  nmcli device wifi list
  nmcli device wifi connect <SSID> password <PASS>

FULL DOCS:
  cat ~/README.md                 # tools installed on this system
  cat /etc/quickref               # this file
─────────────────────────────────────────────────────────────
EOF

section "Configuring bash greeting"
cat > /etc/profile.d/zz-quickref.sh <<'EOF'
# Show quickref on login (interactive bash only, skip in scripts)
case "$-" in *i*)
    [ -f /etc/quickref ] && cat /etc/quickref
    ;;
esac
EOF
chmod +x /etc/profile.d/zz-quickref.sh

section "Configuring fish greeting + default shell"
mkdir -p /etc/fish/conf.d
cat > /etc/fish/conf.d/quickref.fish <<'EOF'
function fish_greeting
    if test -f /etc/quickref
        cat /etc/quickref
    end
end
EOF
# fish was already set as login shell at user creation; double-check:
chsh -s /usr/bin/fish diego 2>/dev/null || true

# README at /home/diego/README.md will be written by install-debian.sh
# (separate file, sourced from TOOLS.md — keeps chroot-setup minimal)

section "Cleaning apt cache"
apt-get clean
rm -rf /var/lib/apt/lists/*

section "Removing policy-rc.d"
rm -f /usr/sbin/policy-rc.d

log "Chroot setup complete."
