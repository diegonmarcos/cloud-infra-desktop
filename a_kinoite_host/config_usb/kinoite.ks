# Fedora Kinoite USB - Portable OS with Openbox
# Target: USB stick (~28GB)
# User: diego | Password: 1234567890
# Used by bootc-image-builder (only user/services/%post are processed)

# Language and keyboard
lang en_US.UTF-8
keyboard us
timezone UTC --utc

# Network
network --bootproto=dhcp --device=link --activate --onboot=yes
network --hostname=kinoite-usb

# Accounts
rootpw --plaintext 1234567890
user --name=diego --password=1234567890 --plaintext --groups=wheel

# Services
services --enabled=sshd,NetworkManager

%post --log=/root/ks-post.log
#!/bin/bash

# Enable SSH password auth
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# Sudoers for diego
echo "diego ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/diego
chmod 440 /etc/sudoers.d/diego

# Create script to install Openbox on first boot
cat > /home/diego/install-openbox.sh << 'EOF'
#!/bin/bash
# Run this after first boot to switch to Openbox
echo "Installing Openbox environment..."
rpm-ostree install openbox obconf obmenu tint2 feh nitrogen pcmanfm lxappearance xterm network-manager-applet
echo ""
echo "Reboot required. After reboot, select 'Openbox' session at login screen."
echo "Run: systemctl reboot"
EOF
chmod +x /home/diego/install-openbox.sh
chown diego:diego /home/diego/install-openbox.sh

# Reduce writes for USB longevity
cat >> /etc/fstab << 'EOF'
# Reduce USB writes
tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0
tmpfs /var/log tmpfs defaults,noatime,mode=0755 0 0
EOF

%end
