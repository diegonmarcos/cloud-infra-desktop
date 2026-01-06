# Kali Linux Security OS Setup

> **Device**: Surface Pro 8
> **Partition**: nvme0n1p4 (~20GB ext4)
> **Purpose**: Penetration testing and security auditing
> **Encryption**: None (intentionally unencrypted for isolation)

---

## Overview

Kali Linux is installed as a dedicated security testing OS, completely isolated from the encrypted NixOS partition. This provides:

- **Clean separation**: Security tools run outside the main encrypted environment
- **Forensic capability**: Can analyze the system without mounting encrypted data
- **Deniability**: Kali doesn't require LUKS password to boot
- **Professional tooling**: Full Kali tool suite available

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          KALI LINUX ARCHITECTURE                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   nvme0n1p4 (ext4, ~20GB)                                                  │
│   ├── /boot/                     Kali kernel + initrd                      │
│   ├── /usr/                      Kali tools + binaries                     │
│   ├── /home/kali/                User data                                 │
│   └── /opt/                      Additional tools                          │
│                                                                             │
│   Isolation:                                                                │
│   ├── NO access to nvme0n1p6 (LUKS encrypted)                             │
│   ├── NO access to NixOS /nix store                                       │
│   ├── NO access to user vault                                              │
│   └── Separate network namespace (optional)                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Installation Options

### Option 1: Kali Full (Recommended for Surface Pro)

Full desktop environment with all tools.

```bash
# Download Kali installer ISO
# https://www.kali.org/get-kali/#kali-installer-images

# Boot from USB, select custom partitioning
# Target: /dev/nvme0n1p4 (ext4)
# Mount point: /
# Install bootloader to partition (not MBR)
```

### Option 2: Kali NetInstaller (Minimal)

Minimal install, add tools as needed.

```bash
# Download Kali NetInstaller
# https://www.kali.org/get-kali/#kali-installer-images

# Select "minimal" during install
# Add tool categories post-install:
sudo apt install kali-tools-web
sudo apt install kali-tools-wireless
sudo apt install kali-tools-exploitation
```

### Option 3: Kali Live (No Install)

Run from USB without installation.

- Useful for one-off assessments
- No persistence by default
- Can add persistence partition to USB

---

## Post-Installation Setup

### 1. Update System

```bash
sudo apt update && sudo apt upgrade -y
sudo apt dist-upgrade -y
```

### 2. Install Surface Pro Drivers

```bash
# Add Surface kernel repository
wget -qO - https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc \
  | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/linux-surface.gpg > /dev/null

echo "deb [arch=amd64] https://pkg.surfacelinux.com/debian release main" \
  | sudo tee /etc/apt/sources.list.d/linux-surface.list

sudo apt update
sudo apt install linux-image-surface linux-headers-surface iptsd libwacom-surface
```

### 3. Configure Network

```bash
# WiFi
nmcli device wifi list
nmcli device wifi connect "SSID" password "PASSWORD"

# Verify connectivity
ping -c 4 8.8.8.8
```

### 4. Configure User

```bash
# Change default password (kali:kali)
passwd

# Optional: Create non-root user
sudo adduser pentester
sudo usermod -aG sudo pentester
```

---

## Essential Tools

### Pre-installed (Kali Full)

| Category | Tools |
|----------|-------|
| **Information Gathering** | nmap, masscan, recon-ng, theHarvester |
| **Vulnerability Analysis** | nikto, wpscan, sqlmap |
| **Web Applications** | burpsuite, zap, wfuzz, gobuster |
| **Exploitation** | metasploit, searchsploit, msfvenom |
| **Password Attacks** | john, hashcat, hydra, medusa |
| **Wireless** | aircrack-ng, wifite, kismet |
| **Forensics** | autopsy, sleuthkit, volatility |
| **Reporting** | cutycapt, recordmydesktop |

### Additional Recommended Tools

```bash
# SecLists wordlists
sudo apt install seclists

# CrackMapExec
sudo apt install crackmapexec

# Bloodhound (AD enumeration)
sudo apt install bloodhound

# Impacket
sudo apt install python3-impacket

# Covenant (C2 alternative to Metasploit)
# Manual installation required
```

---

## Workflows

### 1. Network Penetration Test

```bash
# 1. Discovery
nmap -sn 192.168.1.0/24

# 2. Port Scan
nmap -sV -sC -p- 192.168.1.100

# 3. Vulnerability Scan
nmap --script vuln 192.168.1.100

# 4. Exploitation (Metasploit)
msfconsole
use exploit/...
set RHOSTS 192.168.1.100
exploit
```

### 2. Web Application Test

```bash
# 1. Directory Enumeration
gobuster dir -u http://target.com -w /usr/share/seclists/Discovery/Web-Content/directory-list-2.3-medium.txt

# 2. Start BurpSuite
burpsuite

# 3. SQL Injection Test
sqlmap -u "http://target.com/page?id=1" --dbs

# 4. XSS Testing (manual or via ZAP)
zaproxy
```

### 3. Wireless Assessment

```bash
# 1. Put adapter in monitor mode
sudo airmon-ng start wlan0

# 2. Scan networks
sudo airodump-ng wlan0mon

# 3. Capture handshake
sudo airodump-ng -c [channel] --bssid [AP MAC] -w capture wlan0mon

# In another terminal:
sudo aireplay-ng -0 1 -a [AP MAC] -c [Client MAC] wlan0mon

# 4. Crack password
aircrack-ng -w /usr/share/wordlists/rockyou.txt capture-01.cap
```

---

## Isolation Best Practices

### Network Isolation

```bash
# Create isolated network namespace
sudo ip netns add pentest
sudo ip link add veth0 type veth peer name veth1
sudo ip link set veth1 netns pentest
sudo ip netns exec pentest ip addr add 10.0.0.1/24 dev veth1
sudo ip netns exec pentest ip link set veth1 up

# Run tools in isolated namespace
sudo ip netns exec pentest nmap ...
```

### VM Isolation (Alternative)

For maximum isolation, run Kali in a VM from NixOS:

```nix
# In NixOS configuration.nix (microvm.nix)
microvm.vms.kali-security = {
  config = {
    microvm = {
      hypervisor = "qemu";
      vcpu = 4;
      mem = 4096;
      volumes = [{
        image = "kali-vm.qcow2";
        mountPoint = "/";
        size = 30720;
      }];
    };
  };
};
```

---

## Boot Entry

### rEFInd Configuration

```bash
# /boot/efi/EFI/refind/refind.conf

menuentry "Kali Linux" {
    icon     /EFI/refind/icons/os_kali.png
    volume   "Kali"
    loader   /boot/vmlinuz-*-surface
    initrd   /boot/initrd.img-*-surface
    options  "root=/dev/nvme0n1p4 ro quiet splash"
}
```

### GRUB Configuration (Alternative)

```bash
# /etc/grub.d/40_custom

menuentry "Kali Linux" {
    set root=(hd0,gpt4)
    linux /boot/vmlinuz-* root=/dev/nvme0n1p4 ro quiet
    initrd /boot/initrd.img-*
}

# Regenerate GRUB
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

---

## Security Considerations

### DO

- Keep Kali updated regularly
- Use non-root user for general work
- Enable firewall when not actively testing
- Document all assessments
- Only test systems you have authorization for

### DON'T

- Store sensitive data on Kali partition (unencrypted)
- Leave Kali services exposed (SSH, etc.)
- Use Kali for general browsing/daily use
- Run untrusted tools without review
- Conduct tests without written authorization

---

## Troubleshooting

### WiFi Not Working

```bash
# Check if adapter detected
lspci | grep -i wireless
lsusb | grep -i wireless

# Load drivers
sudo modprobe iwlwifi

# Restart NetworkManager
sudo systemctl restart NetworkManager
```

### Surface Touch Not Working

```bash
# Install iptsd (Surface touch processor daemon)
sudo apt install iptsd
sudo systemctl enable iptsd
sudo systemctl start iptsd
```

### Boot Issues

```bash
# From Alpine Recovery or NixOS:
# Reinstall GRUB to Kali partition
sudo mount /dev/nvme0n1p4 /mnt
sudo mount --bind /dev /mnt/dev
sudo mount --bind /proc /mnt/proc
sudo mount --bind /sys /mnt/sys
sudo chroot /mnt
update-grub
exit
```

---

## Related Documentation

| Document | Path | Purpose |
|----------|------|---------|
| Main Architecture | `0_spec/ARCHITECTURE.md` | High-level overview |
| Disk Layout | `0_spec/DISK_LAYOUT.md` | Partition details |
| Roadmap | `0_spec/ROADMAP.md` | Implementation plan |
| Alpine Recovery | `a_alpine_fallback/build.sh` | Recovery OS |
| Windows Webcam | `a_win11_webcam/SETUP.md` | Webcam streaming |
