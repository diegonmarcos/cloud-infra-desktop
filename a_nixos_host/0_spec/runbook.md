# NixOS Host Runbook

> **Device**: Surface Pro 8
> **OS**: NixOS 24.11 with Full Impermanence
> **Updated**: 2026-01-06

---

## Quick Reference

| Credential | Value | Notes |
|------------|-------|-------|
| **User** | `user` | UID 1000 |
| **Password** | `1234567890` | **CHANGE AFTER SETUP** |
| **LUKS** | Same as user | Slot 0 |
| **USB Key** | Slot 1 | Auto-unlock if present |
| **SSH** | Port 22 open | Password enabled |

---

## Boot Scenarios

### Normal Boot (USB Key Present)

1. Power on Surface Pro 8
2. USB key detected (Ventoy)
3. LUKS unlocks automatically
4. SDDM login appears
5. Select session (Plasma/GNOME/Openbox)

### Normal Boot (No USB Key)

1. Power on Surface Pro 8
2. LUKS password prompt appears
3. Enter password: `1234567890`
4. SDDM login appears

### Boot to Alpine Recovery

1. Power on Surface Pro 8
2. Select "Alpine Recovery" from boot menu
3. No password required
4. Recovery shell available

### Boot to Kali Linux

1. Power on Surface Pro 8
2. Select "Kali Linux" from boot menu
3. No LUKS involved (separate partition)
4. Login with Kali credentials
5. Use for security testing/pentesting

### Boot to Windows 11 Webcam

1. Power on Surface Pro 8
2. Select "Windows 11" from boot menu
3. No LUKS involved (separate partition)
4. Use for webcam streaming

---

## Daily Operations

### Update System

```bash
cd /home/diego/mnt_git/unix/a_nixos_host

# Update flake inputs
nix flake update

# Check configuration
nix flake check

# Build and switch
sudo nixos-rebuild switch --flake .#surface
```

### Rollback

```bash
# Rollback to previous generation
sudo nixos-rebuild switch --rollback

# Or select generation from GRUB menu at boot

# List all generations
sudo nix-env --list-generations -p /nix/var/nix/profiles/system
```

### Garbage Collection

```bash
# Remove old generations (keep last 7 days)
sudo nix-collect-garbage --delete-older-than 7d

# Optimize store (deduplication)
sudo nix store optimise
```

---

## Vault Operations

### Open Vault

```bash
# With USB key
tomb open ~/vault.tomb -k /media/VTOYEFI/.vault/vault.key

# With password (if no USB)
tomb open ~/vault.tomb
```

### Close Vault

```bash
tomb close vault
```

### List Open Tombs

```bash
tomb list
```

### Create New Vault (First Time)

```bash
# Create 1GB tomb file
tomb dig -s 1024 ~/vault.tomb

# Create key (store on USB!)
tomb forge /media/VTOYEFI/.vault/vault.key

# Lock tomb with key
tomb lock ~/vault.tomb -k /media/VTOYEFI/.vault/vault.key
```

---

## Container Operations

### Distrobox

```bash
# Create Arch container
distrobox create --name arch-dev --image archlinux:latest

# Enter container
distrobox enter arch-dev

# Export app to host
distrobox-export --app code

# List containers
distrobox list
```

### Podman

```bash
# Run container (rootless)
podman run -d --name nginx -p 8080:80 nginx

# List containers
podman ps -a

# Stop and remove
podman stop nginx && podman rm nginx
```

### microvm.nix (Security VMs)

```bash
# Start a microVM
systemctl start microvm@sandbox

# Connect to VM console
microvm -c sandbox

# Stop VM
systemctl stop microvm@sandbox

# Verify isolation (different kernel)
# Inside VM: uname -r shows guest kernel
```

### Flatpak

```bash
# Add Flathub (first time)
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# Install app
flatpak install flathub com.visualstudio.code

# Run app
flatpak run com.visualstudio.code

# Update all
flatpak update
```

### Waydroid (Android)

```bash
# Initialize (first time)
sudo waydroid init

# Start session
waydroid session start

# Show full UI
waydroid show-full-ui

# Stop session
waydroid session stop
```

---

## Mount Operations

### Cloud Storage

```bash
# Mount all (script)
~/mnt_git/unix/b_mnt/mount.sh start

# Unmount all
~/mnt_git/unix/b_mnt/mount.sh stop

# Check status
~/mnt_git/unix/b_mnt/mount.sh status

# Manual rclone mount
rclone mount gdrive_dnm: ~/mnt_cloud/gdrive_personal --vfs-cache-mode writes --daemon
```

### Remote Servers

```bash
# SSHFS mount
sshfs ubuntu@130.110.251.193:/home/ubuntu ~/mnt_remote/oci_micro_1 -o IdentityFile=~/.ssh/id_rsa

# Unmount
fusermount -u ~/mnt_remote/oci_micro_1
```

---

## Troubleshooting

### LUKS Won't Unlock

```bash
# From Alpine Recovery:
cryptsetup open /dev/nvme0n1p5 pool

# Check keyslots
cryptsetup luksDump /dev/nvme0n1p5

# Add new key (if needed)
sudo cryptsetup luksAddKey /dev/nvme0n1p5
```

### USB Keyfile Not Working

Check initrd has vfat module:
```nix
# In hardware-configuration.nix
boot.initrd.availableKernelModules = [
  "vfat"    # MUST be present for USB keyfile
  "nls_cp437"
  "nls_iso8859_1"
  # ... other modules
];
```

### No Network After Boot

```bash
# Check NetworkManager
systemctl status NetworkManager

# Restart
sudo systemctl restart NetworkManager

# Check connections persist
ls /persist/etc/NetworkManager/system-connections/
```

### Desktop Session Missing

```bash
# Check session files
ls /run/current-system/etc/wayland-sessions/

# Restart SDDM
sudo systemctl restart sddm
```

### Waydroid Not Starting

```bash
# Check binder modules
lsmod | grep binder

# Reinitialize
sudo waydroid init

# Check logs
journalctl -u waydroid-container
```

### Flatpak Apps Missing Data

Ensure `.var` is in persistence:
```nix
# In configuration.nix
environment.persistence."/persist".users.user.directories = [
  ".var"    # Flatpak user data
];
```

### microvm.nix Not Working

```bash
# Check if microvm host is enabled
systemctl status microvm@sandbox

# Check KVM is available
ls /dev/kvm

# Check microvm.nix flake input is added
nix flake metadata | grep microvm
```

---

## Subvolume Migration (Phase 2)

### Prerequisites

- Full backup completed
- Boot into Alpine Recovery
- LUKS password known

### Step 1: Backup Current Data

```bash
# From Alpine Recovery
cryptsetup open /dev/nvme0n1p5 pool
mount /dev/mapper/pool /mnt

# Create backups
btrfs send /mnt/@root-nixos > /backup/root-nixos.btrfs
btrfs send /mnt/@home-nixos > /backup/home-nixos.btrfs
```

### Step 2: Create New Structure

```bash
# Create semantic subvolumes
btrfs subvolume create /mnt/@system
btrfs subvolume create /mnt/@system/nix
btrfs subvolume create /mnt/@system/state
btrfs subvolume create /mnt/@system/logs

btrfs subvolume create /mnt/@user
btrfs subvolume create /mnt/@user/home

btrfs subvolume create /mnt/@shared
btrfs subvolume create /mnt/@shared/containers
btrfs subvolume create /mnt/@shared/flatpak
btrfs subvolume create /mnt/@shared/microvm
btrfs subvolume create /mnt/@shared/waydroid
```

### Step 3: Migrate Data

```bash
# Copy with reflinks (fast, no extra space)
cp -a --reflink=auto /mnt/@root-nixos/nix/* /mnt/@system/nix/
cp -a --reflink=auto /mnt/@root-nixos/persist/* /mnt/@system/state/
cp -a --reflink=auto /mnt/@home-nixos/* /mnt/@user/home/
```

### Step 4: Verify and Delete Old

```bash
# Verify new structure
btrfs subvolume list /mnt

# Delete old (after verification!)
btrfs subvolume delete /mnt/@root-nixos
btrfs subvolume delete /mnt/@home-nixos
btrfs subvolume delete /mnt/@root-kinoite  # If exists
btrfs subvolume delete /mnt/@home-kinoite  # If exists
```

---

## Alpine Recovery Procedures

### Unlock and Mount BTRFS

```bash
# Unlock LUKS
cryptsetup open /dev/nvme0n1p5 pool

# Mount pool
mount /dev/mapper/pool /mnt

# Mount specific subvolume
mount -o subvol=@system/nix /dev/mapper/pool /mnt/nix
```

### Rebuild GRUB

```bash
# Mount necessary partitions
mount /dev/nvme0n1p2 /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot/efi

# Chroot and update
chroot /mnt /bin/bash
grub-mkconfig -o /boot/grub/grub.cfg
exit
```

### Restore from Backup

```bash
# Receive backup
btrfs receive /mnt < /backup/root-nixos.btrfs

# Rename if needed
btrfs subvolume snapshot /mnt/root-nixos /mnt/@system/nix
```

---

## File Locations

| File | Path |
|------|------|
| **Flake** | `/home/diego/mnt_git/unix/a_nixos_host/flake.nix` |
| **Configuration** | `/home/diego/mnt_git/unix/a_nixos_host/configuration.nix` |
| **Hardware Config** | `/home/diego/mnt_git/unix/a_nixos_host/hardware-configuration.nix` |
| **Architecture Spec** | `/home/diego/mnt_git/unix/0_spec/ARCHITECTURE.md` |
| **Disk Layout Spec** | `/home/diego/mnt_git/unix/0_spec/DISK_LAYOUT.md` |
| **Roadmap** | `/home/diego/mnt_git/unix/0_spec/ROADMAP.md` |
| **Kali Setup** | `/home/diego/mnt_git/unix/a_kali_security/SETUP.md` |
| **Vault File** | `/home/user/vault.tomb` |
| **Vault Key** | `/media/VTOYEFI/.vault/vault.key` (USB) |
| **LUKS Key** | `/media/VTOYEFI/.luks/surface.key` (USB) |

---

## Verification Checklist

### After Fresh Install

- [ ] System boots with USB key (auto-unlock)
- [ ] System boots without USB (password prompt)
- [ ] All desktop sessions available (KDE, GNOME, Openbox)
- [ ] WiFi connects and persists
- [ ] Bluetooth pairs and persists
- [ ] SSH access works
- [ ] Flatpak apps install and run
- [ ] Podman containers run
- [ ] Waydroid initializes

### After Configuration Change

- [ ] `nix flake check` passes
- [ ] Build succeeds
- [ ] Switch succeeds
- [ ] Reboot successful
- [ ] Persistence working (check after reboot)

### After Subvolume Migration

- [ ] All data accessible
- [ ] Correct subvolume names
- [ ] Correct mount points
- [ ] Boot completes successfully
- [ ] Containers still work
- [ ] User data intact

### Kali Linux

- [ ] Kali boots from boot menu
- [ ] WiFi connects
- [ ] Security tools work (nmap, burpsuite)
- [ ] Isolated from LUKS partition (cannot access encrypted data)
