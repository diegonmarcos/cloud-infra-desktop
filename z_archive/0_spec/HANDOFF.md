# Migration Handoff: Dual Profile Architecture

> **Date**: 2026-01-02
> **Device**: Surface Pro 8 (8GB RAM, 256GB NVMe)
> **Goal**: ANON/AUTH profiles with nested LUKS encryption

---

## Current State

```
┌─────────────────────────────────────────────────┐
│              Current Disk Layout                │
├─────────────────────────────────────────────────┤
│ nvme0n1p1 │ 100 MB  │ EFI      │ Boot          │
│ nvme0n1p2 │ 16 MB   │ Reserved │ Microsoft     │
│ nvme0n1p3 │ 117.5 GB│ NTFS     │ Windows       │
│ nvme0n1p4 │ 857 MB  │ NTFS     │ Recovery      │
│ nvme0n1p5 │ 118.4 GB│ ext4     │ Ubuntu KDE ←  │
└─────────────────────────────────────────────────┘
```

---

## Target State

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              Target Disk Layout                                  │
├─────────────────────────────────────────────────────────────────────────────────┤
│  p1 │ 500 MB  │ FAT32       │ EFI System                                       │
│  p2 │ ~215 GB │ OUTER LUKS  │ Encrypted Pool (includes swap file for security) │
│  p3 │ 20 GB   │ NTFS        │ Windows (Camera fallback)                        │
└─────────────────────────────────────────────────────────────────────────────────┘

NOTE: Swap is inside LUKS as /mnt/pool/swapfile (encrypted) - no separate partition.

OUTER LUKS contains BTRFS Pool:
├── @kde          (~10 GB)  → KDE minimal OS
├── @light        (~5 GB)   → Openbox minimal OS
├── @android      (~15 GB)  → Waydroid data
├── @tools-anon   (~5 GB)   → Tor, DNSCrypt, Privacy containers
├── @vault-anon   (~1 GB)   → Burner identities
├── @shared-anon  (~20 GB)  → Anonymous files
├── auth.luks     (~80 GB)  → INNER LUKS (AUTH only)
└── @snapshots    (dynamic) → Backups

INNER LUKS (auth.luks) contains:
├── @tools-auth   (~10 GB)  → Claude, Git, Dev containers
├── @vault-auth   (~1 GB)   → Personal SSH/GPG/API
└── @shared-auth  (~60 GB)  → Documents, Projects
```

---

## Security Model

```
Password "anon" → Unlocks OUTER only → Sees ANON profile
Password "auth" → Unlocks OUTER + INNER → Sees ANON + AUTH profiles

┌─────────────────────────────────────────────────────────────────┐
│                         OUTER LUKS                               │
│                   (Both passwords unlock)                        │
│                                                                  │
│   @kde  @light  @android  @tools-anon  @vault-anon  @shared-anon │
│                                                                  │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                    INNER LUKS                            │   │
│   │              (Only AUTH password unlocks)                │   │
│   │                                                          │   │
│   │      @tools-auth    @vault-auth    @shared-auth         │   │
│   │                                                          │   │
│   └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Migration Strategy

### Phase 0: Backup (CRITICAL)

- [ ] Backup Ubuntu home folder to external drive
- [ ] Backup Windows important files
- [ ] Export browser bookmarks/passwords
- [ ] List installed packages: `dpkg --get-selections > packages.txt`
- [ ] Backup SSH keys, GPG keys (already in vault)
- [ ] Backup /etc configs if customized

### Phase 1: Prepare Media

- [ ] Download Kinoite ISO (with Surface kernel if available)
- [ ] Download Arch ISO
- [ ] Download Win11 ISO
- [ ] Create bootable USB with Ventoy (multi-ISO)

### Phase 2: Partition Disk

```
Delete all partitions → Create new layout
```
- [ ] Boot from USB (Ventoy with multiple ISOs)
- [ ] Use GParted or fdisk to create:
  - p1: 500 MB FAT32 (EFI)
  - p2: ~215 GB (for LUKS - includes swap as file)
  - p3: 20 GB NTFS (Windows)

**Note:** No separate swap partition - swap will be encrypted file inside LUKS.

### Phase 3: Setup OUTER LUKS

```bash
# Create LUKS container (first password = ANON)
cryptsetup luksFormat /dev/nvme0n1p2
# Enter ANON password

# Add second key slot (AUTH password)
cryptsetup luksAddKey /dev/nvme0n1p2
# Enter existing password, then AUTH password

# Open outer LUKS
cryptsetup open /dev/nvme0n1p2 cryptouter
```

### Phase 4: Create BTRFS and Subvolumes (Outer)

```bash
# Create BTRFS filesystem
mkfs.btrfs -L pool /dev/mapper/cryptouter
mount /dev/mapper/cryptouter /mnt

# OS roots (shared by both profiles)
btrfs subvolume create /mnt/@kde
btrfs subvolume create /mnt/@light
btrfs subvolume create /mnt/@android

# ANON profile
btrfs subvolume create /mnt/@tools-anon
btrfs subvolume create /mnt/@vault-anon
btrfs subvolume create /mnt/@shared-anon

# Snapshots
btrfs subvolume create /mnt/@snapshots

# Create encrypted swap file (inside LUKS pool)
dd if=/dev/zero of=/mnt/swapfile bs=1G count=8 status=progress
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
```

### Phase 5: Create INNER LUKS for AUTH

```bash
# Create container file (~80GB)
dd if=/dev/zero of=/mnt/auth.luks bs=1M count=80000 status=progress

# Format as LUKS
cryptsetup luksFormat /mnt/auth.luks
# Enter AUTH-inner password (can be same as AUTH)

# Create keyfile for auto-unlock
dd if=/dev/urandom of=/mnt/.auth-keyfile bs=4096 count=1
chmod 000 /mnt/.auth-keyfile
cryptsetup luksAddKey /mnt/auth.luks /mnt/.auth-keyfile

# Open inner LUKS
cryptsetup open /mnt/auth.luks cryptinner --key-file /mnt/.auth-keyfile

# Create BTRFS in inner
mkfs.btrfs -L auth /dev/mapper/cryptinner
mount /dev/mapper/cryptinner /mnt/auth

# AUTH profile subvolumes
btrfs subvolume create /mnt/auth/@tools-auth
btrfs subvolume create /mnt/auth/@vault-auth
btrfs subvolume create /mnt/auth/@shared-auth

umount /mnt/auth
```

**Checkpoint: Dual LUKS structure ready.**

### Phase 6: Install KDE (Kinoite) - MINIMAL

- [ ] Mount @kde subvolume
- [ ] Install Fedora Kinoite (minimal install)
- [ ] Configure /etc/crypttab for outer LUKS
- [ ] Configure initramfs to handle AUTH keyfile logic
- [ ] Install podman only (NOT full dev tools)

#### Install linux-surface (KDE)

```bash
# Add linux-surface repository
sudo wget -O /etc/yum.repos.d/linux-surface.repo \
  https://pkg.surfacelinux.com/fedora/linux-surface.repo
sudo rpm --import https://pkg.surfacelinux.com/keys/surface.asc

# Install Surface kernel and tools
rpm-ostree install \
  kernel-surface \
  kernel-surface-devel \
  iptsd \
  libwacom-surface \
  surface-control

# Reboot and enable touchscreen daemon
systemctl reboot
sudo systemctl enable --now iptsd
```

- [ ] Verify: touch, pen, wifi, audio work

**Checkpoint: KDE boots with LUKS password and Surface hardware works.**

### Phase 7: Install Light (Arch+Openbox) - MINIMAL

- [ ] Mount @light subvolume
- [ ] Install minimal Arch + Openbox + terminal + file manager ONLY
- [ ] Configure mkinitcpio for LUKS
- [ ] Install podman only

#### Install linux-surface (Arch)

```bash
# Add linux-surface repository to /etc/pacman.conf
cat >> /etc/pacman.conf << 'EOF'

[linux-surface]
Server = https://pkg.surfacelinux.com/arch/
EOF

# Import signing key
curl -s https://pkg.surfacelinux.com/keys/surface.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key 56C464BAAC421453

# Install Surface packages
sudo pacman -Syu
sudo pacman -S linux-surface linux-surface-headers iptsd surface-control

# Update initramfs and bootloader
sudo mkinitcpio -P

# Enable touchscreen daemon
sudo systemctl enable iptsd
```

- [ ] Verify: touch, pen, wifi, audio work

**Checkpoint: Light Arch boots with Surface hardware support.**

### Phase 7.5: Create Users + Auto-Login

Create users in BOTH @kde and @light subvolumes:

```bash
# ═══════════════════════════════════════════════════════════════════════════
# ANON user - NO host sudo, but can run containers
# ═══════════════════════════════════════════════════════════════════════════
useradd -m -u 1000 -s /bin/bash anon
echo "anon:1234567890" | chpasswd
usermod -aG podman anon  # Can run rootless containers
# NOT in wheel group - cannot sudo on host

# ═══════════════════════════════════════════════════════════════════════════
# AUTH user (diego) - full sudo + containers
# ═══════════════════════════════════════════════════════════════════════════
useradd -m -u 1000 -G wheel -s /bin/bash diego
echo "diego:1234567890" | chpasswd
usermod -aG podman diego
echo "diego ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/diego
chmod 440 /etc/sudoers.d/diego

# ═══════════════════════════════════════════════════════════════════════════
# Enable rootless containers (user can be root INSIDE containers)
# ═══════════════════════════════════════════════════════════════════════════
loginctl enable-linger anon
loginctl enable-linger diego
```

#### Configure Auto-Login (KDE - SDDM)

```bash
# /etc/sddm.conf.d/autologin.conf
[Autologin]
User=diego          # 'anon' for ANON profile boot
Session=plasma.desktop
```

#### Configure Auto-Login (Light - getty)

```bash
# /etc/systemd/system/getty@tty1.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin diego --noclear %I $TERM
# 'anon' for ANON profile boot
```

- [ ] Create `anon` user in @kde (NO wheel, YES podman)
- [ ] Create `anon` user in @light (NO wheel, YES podman)
- [ ] Create `diego` user in @kde (wheel + NOPASSWD + podman)
- [ ] Create `diego` user in @light (wheel + NOPASSWD + podman)
- [ ] Enable linger for both users (rootless containers)
- [ ] Configure SDDM auto-login for KDE
- [ ] Configure getty auto-login for Light
- [ ] Verify anon CANNOT sudo on host
- [ ] Verify anon CAN run `podman run --rm alpine whoami` → root
- [ ] Verify diego sudo NOPASSWD works

**Checkpoint: Users configured - anon (containers only), diego (full sudo).**

### Phase 8: Setup Waydroid (Android)

- [ ] Install Waydroid in KDE: `rpm-ostree install waydroid`
- [ ] Initialize: `sudo waydroid init -s GAPPS`
- [ ] Test fullscreen mode: `waydroid show-full-ui`
- [ ] Verify touch, Play Store work

**Checkpoint: Android UI available.**

### Phase 9: Build Podman Containers

**ANON Container:**
- [ ] Build: `podman build -t cloud-connect:anon -f Containerfile.anon .`
- [ ] Test Tor, DNSCrypt work

**AUTH Container:**
- [ ] Build: `podman build -t cloud-connect:auth -f Containerfile.auth .`
- [ ] Test Claude, Git, Python work

**Checkpoint: Containers ready.**

### Phase 10: Populate Vaults

**@vault-anon:**
- [ ] Create burner SSH keys
- [ ] Setup Tor configs
- [ ] Create anon service configs

**@vault-auth:**
- [ ] Copy personal SSH keys
- [ ] Copy GPG keys
- [ ] Copy API tokens (Anthropic, Google, GitHub)
- [ ] Copy cloud configs (OCI, GCloud)
- [ ] Set permissions: `chmod 600 -R @vault-auth/`

**Checkpoint: Vaults populated.**

### Phase 11: Install Windows 11 (Debloated)

- [ ] Install Windows 11 to p3 (NTFS)
- [ ] Debloat Windows (see below)
- [ ] Install webcam driver + browser
- [ ] Test webcam works

#### Windows 11 Debloat Steps

**1. During Install:**
- Skip Microsoft account (use `oobe\bypassnro` in cmd)
- Disable all tracking options

**2. Remove Bloatware (PowerShell as Admin):**
```powershell
Get-AppxPackage *3DBuilder* | Remove-AppxPackage
Get-AppxPackage *BingWeather* | Remove-AppxPackage
Get-AppxPackage *Cortana* | Remove-AppxPackage
Get-AppxPackage *GetHelp* | Remove-AppxPackage
Get-AppxPackage *MicrosoftOfficeHub* | Remove-AppxPackage
Get-AppxPackage *MicrosoftSolitaireCollection* | Remove-AppxPackage
Get-AppxPackage *Xbox* | Remove-AppxPackage
# ... etc
```

**3. Disable Telemetry:**
- Download O&O ShutUp10
- Apply recommended settings

**Expected result:** ~12-15 GB install, ~2 GB RAM idle

### Phase 12: Install rEFInd + Configure Boot

- [ ] Install rEFInd bootloader
- [ ] Create boot entries:
  - Light Anon (mounts ANON profile)
  - Light Auth (mounts AUTH profile)
  - KDE Anon
  - KDE Auth
  - Android Anon
  - Android Auth
  - Windows
- [ ] Configure each entry's kernel params for profile selection
- [ ] Test all 7 boot options

**Checkpoint: All boots working.**

### Phase 13: Setup Kata Containers (Mode B)

Kata Containers enable running Light environments as micro-VMs from KDE host.

- [ ] Install Kata on Kinoite: `rpm-ostree install kata-containers`
- [ ] Configure podman to use kata runtime
- [ ] Create Light Anon container image for Kata
- [ ] Create Light Auth container image for Kata
- [ ] Test Kata VM launch from KDE Auth
- [ ] Test Kata VM launch from KDE Anon (only Anon should work)
- [ ] Configure virtio-fs for shared storage access

```bash
# Configure podman for kata
mkdir -p ~/.config/containers
cat > ~/.config/containers/containers.conf << 'EOF'
[engine]
runtime = "kata"
EOF

# Test kata VM
podman run --runtime=kata --rm -it archlinux-openbox:anon
```

**Checkpoint: Kata VMs launch from KDE.**

### Phase 14: Setup QEMU/KVM Windows VM (Mode B)

Enable Windows VM for webcam access without rebooting.

- [ ] Install QEMU/KVM: `rpm-ostree install qemu-kvm libvirt virt-manager`
- [ ] Enable libvirtd service
- [ ] Create Windows VM with USB passthrough
- [ ] Test webcam passthrough in VM
- [ ] Create VM snapshot for quick restore

```bash
# Install virtualization
rpm-ostree install qemu-kvm libvirt virt-manager
systemctl reboot

# Enable libvirt
sudo systemctl enable --now libvirtd

# Create Windows VM
virt-install \
  --name windows-camera \
  --ram 3072 \
  --vcpus 2 \
  --disk /mnt/pool/windows.qcow2,size=20 \
  --cdrom ~/win11.iso \
  --os-variant win11 \
  --graphics spice \
  --hostdev <webcam-usb-id>
```

**Checkpoint: Windows VM with webcam works.**

### Phase 15: Final Verification

**Mode A (Multi-boot):**
- [ ] Test ANON password → only ANON accessible
- [ ] Test AUTH password → ANON + AUTH accessible
- [ ] Test containers work in each profile
- [ ] Test vault access correct per profile

**Mode B (VM from KDE):**
- [ ] Test KDE Auth → Light Anon VM works
- [ ] Test KDE Auth → Light Auth VM works
- [ ] Test KDE Auth → Windows VM + webcam works
- [ ] Test KDE Anon → Light Anon VM works
- [ ] Test KDE Anon → Light Auth VM **BLOCKED** (security check)
- [ ] Test virtio-fs shared storage in VMs

**Final:**
- [ ] Final backup of new setup

---

## Rollback Plan

| Phase | Rollback Option |
|-------|-----------------|
| 0-1 | Restore from backup |
| 2 | **Point of no return** - All partitions deleted |
| 3-12 | Boot from USB, reconfigure |
| 13-14 | Remove Kata/QEMU packages, revert to Mode A only |
| 15 | N/A - verification only |

**CRITICAL: Complete backup in Phase 0 before proceeding!**

---

## Verification Checklist

### Mode A: Multi-Boot Tests

| Test | KDE | Light | Android | Windows |
|------|-----|-------|---------|---------|
| LUKS unlock (ANON) | [ ] | [ ] | [ ] | N/A |
| LUKS unlock (AUTH) | [ ] | [ ] | [ ] | N/A |
| Inner LUKS (AUTH only) | [ ] | [ ] | [ ] | N/A |
| Boot | [ ] | [ ] | [ ] | [ ] |
| Wifi | [ ] | [ ] | [ ] | [ ] |
| Touch | [ ] | [ ] | [ ] | [ ] |
| Audio | [ ] | [ ] | [ ] | [ ] |
| @tools mount | [ ] | [ ] | [ ] | N/A |
| @vault mount | [ ] | [ ] | [ ] | N/A |
| @shared mount | [ ] | [ ] | [ ] | N/A |
| Container works | [ ] | [ ] | N/A | N/A |
| Webcam | N/A | N/A | N/A | [ ] |

### Mode B: VM Tests (from KDE Host)

| Test | KDE Auth Host | KDE Anon Host |
|------|---------------|---------------|
| Kata Light Anon VM | [ ] | [ ] |
| Kata Light Auth VM | [ ] | [ ] BLOCKED |
| QEMU Windows VM | [ ] | [ ] |
| Windows webcam passthrough | [ ] | [ ] |
| virtio-fs @shared-anon | [ ] | [ ] |
| virtio-fs @shared-auth | [ ] | [ ] BLOCKED |
| Waydroid works | [ ] | [ ] |

---

## Files to Migrate

**To @shared-auth:**
```
~/Documents/     → @shared-auth/Documents/
~/Downloads/     → @shared-auth/Downloads/
~/Projects/      → @shared-auth/Projects/
~/Media/         → @shared-auth/Media/
```

**To @vault-auth:**
```
~/.ssh/          → @vault-auth/ssh/
~/.gnupg/        → @vault-auth/gpg/
~/vault/         → @vault-auth/
API keys         → @vault-auth/api/
```

**To @vault-anon:**
```
Tor configs      → @vault-anon/tor/
Burner keys      → @vault-anon/burner-keys/
```

---

## Notes

**Hardware:**
- Surface Pro 8 webcam (IPU6) requires Windows
- Kinoite needs linux-surface kernel for touch/pen

**Security:**
- ANON password: Opens outer LUKS only
- AUTH password: Opens outer + inner LUKS
- Both encrypted from outside (theft protection)
- ANON can't see AUTH data (inner LUKS locked)
- AUTH can see everything

**Architecture:**
- Minimal OS (~5-10 GB each)
- Tools in Podman containers
- Separate vaults per profile
- 7 boot options (3 OS × 2 profiles + Windows)

**Container Profiles:**
- cloud-connect:anon → Tor, DNSCrypt, Privacy
- cloud-connect:auth → Claude, Git, Python, Node, Rust
