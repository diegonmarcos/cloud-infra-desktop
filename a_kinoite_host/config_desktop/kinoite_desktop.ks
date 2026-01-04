# ═══════════════════════════════════════════════════════════════════════════
# Fedora Kinoite Desktop - Kickstart Configuration
# ═══════════════════════════════════════════════════════════════════════════
#
# Boot parameter: inst.ks=http://192.168.122.1:8888/kinoite_desktop.ks
#
# Features:
#   - User diego with sudo NOPASSWD
#   - SSH enabled from first boot
#   - Firewall allows SSH
#   - Ready for podman tools
#
# ═══════════════════════════════════════════════════════════════════════════

# Text mode install (faster, no GUI needed)
text

# Language and locale
lang en_US.UTF-8
keyboard us
timezone UTC --utc

# Network - DHCP, activate on boot
network --bootproto=dhcp --device=link --activate --onboot=yes --hostname=kinoite-host

# Root disabled
rootpw --lock

# User diego with wheel group
user --name=diego --password=1234567890 --plaintext --groups=wheel

# Ostree for Kinoite (from local ISO)
ostreesetup --osname="fedora" --remote="fedora" --url="file:///ostree/repo" --ref="fedora/41/x86_64/kinoite" --nogpg

# Disk - full auto
ignoredisk --only-use=vda
zerombr
clearpart --all --initlabel --drives=vda
autopart --type=plain --fstype=ext4

# Bootloader
bootloader --location=mbr --boot-drive=vda

# Services - enable SSH
services --enabled=sshd,NetworkManager

# Firewall - SSH open
firewall --enabled --ssh

# SELinux
selinux --enforcing

# Reboot when done
reboot

# ═══════════════════════════════════════════════════════════════════════════
# %post - Runs in installed system
# ═══════════════════════════════════════════════════════════════════════════
%post --log=/var/log/ks-post.log

echo "=== Kickstart %post started: $(date) ==="

# ─────────────────────────────────────────────────────────────────────────────
# SSH Configuration
# ─────────────────────────────────────────────────────────────────────────────
echo "[1/5] Configuring SSH..."

# Enable SSH service
systemctl enable sshd.service

# SSH config - allow password auth
cat > /etc/ssh/sshd_config.d/99-kickstart.conf << 'SSHEOF'
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
MaxAuthTries 5
SSHEOF

echo "SSH configured"

# ─────────────────────────────────────────────────────────────────────────────
# Sudo NOPASSWD for diego
# ─────────────────────────────────────────────────────────────────────────────
echo "[2/5] Configuring sudo..."

cat > /etc/sudoers.d/diego << 'SUDOEOF'
diego ALL=(ALL) NOPASSWD: ALL
SUDOEOF
chmod 440 /etc/sudoers.d/diego

echo "Sudo configured"

# ─────────────────────────────────────────────────────────────────────────────
# Firewall - ensure SSH allowed
# ─────────────────────────────────────────────────────────────────────────────
echo "[3/5] Configuring firewall..."

# Use offline command for installed system
firewall-offline-cmd --add-service=ssh 2>/dev/null || true

echo "Firewall configured"

# ─────────────────────────────────────────────────────────────────────────────
# Create directories for diego
# ─────────────────────────────────────────────────────────────────────────────
echo "[4/5] Creating user directories..."

# Kinoite uses /var/home instead of /home
DIEGO_HOME="/var/home/diego"

mkdir -p "$DIEGO_HOME"/.ssh
mkdir -p "$DIEGO_HOME"/podman
chmod 700 "$DIEGO_HOME"/.ssh
chown -R diego:diego "$DIEGO_HOME"

echo "Directories created"

# ─────────────────────────────────────────────────────────────────────────────
# Create marker and info file
# ─────────────────────────────────────────────────────────────────────────────
echo "[5/5] Creating info files..."

cat > "$DIEGO_HOME"/README.txt << 'READMEEOF'
═══════════════════════════════════════════════════════════════════════════
                    Kinoite Desktop - First Boot Complete
═══════════════════════════════════════════════════════════════════════════

SSH is enabled. Connect from host:
  ssh diego@<this-ip>

Password: 1234567890

Next steps:
  1. Copy podman build scripts to ~/podman/
  2. Build containers: cd ~/podman && ./build.sh

═══════════════════════════════════════════════════════════════════════════
READMEEOF

chown diego:diego "$DIEGO_HOME"/README.txt

# Marker file
touch "$DIEGO_HOME"/.kickstart-complete

echo "=== Kickstart %post complete: $(date) ==="

%end
