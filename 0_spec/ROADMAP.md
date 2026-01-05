# Surface Multi-OS Pool - Implementation Roadmap

> **Status**: In Progress
> **Last Updated**: 2026-01-05

---

## Phase 1: Kinoite Base Setup [COMPLETED]

- [x] Update ARCHITECTURE.md with new design
- [x] Backup Kinoite from /pool/@root to /home/diego
- [x] Unmount /pool and delete old nvme0n1p3
- [x] Create nvme0n1p3 (2GB /boot) + nvme0n1p4 (116GB LUKS)
- [x] Format nvme0n1p3 as ext4 /boot
- [x] LUKS format nvme0n1p4 (password: 1234567890)
- [x] Create BTRFS inside LUKS with initial subvolumes
- [x] Restore Kinoite to @root-kinoite
- [x] Copy kernel/initramfs to /boot/kinoite/
- [x] Update GRUB for Kinoite boot

---

## Phase 2: Subvolume Restructure [PENDING]

- [ ] Backup @home contents
- [ ] Rename @home to @home-kinoite
- [ ] Delete @images subvolume
- [ ] Create @home-nixos subvolume
- [ ] Create @shared subvolume
- [ ] Create @android subvolume
- [ ] Update Kinoite fstab for new mount structure
- [ ] Test Kinoite boot with new subvolumes

### Subvolume Commands
```bash
# From Ubuntu with LUKS open:
sudo mount /dev/mapper/pool /mnt/pool

# Backup home
sudo tar -cvf /home/diego/home-backup.tar -C /mnt/pool/@home .

# Rename @home to @home-kinoite
sudo btrfs subvolume snapshot /mnt/pool/@home /mnt/pool/@home-kinoite
sudo btrfs subvolume delete /mnt/pool/@home

# Delete @images
sudo btrfs subvolume delete /mnt/pool/@images

# Create new subvolumes
sudo btrfs subvolume create /mnt/pool/@home-nixos
sudo btrfs subvolume create /mnt/pool/@shared
sudo btrfs subvolume create /mnt/pool/@android

# Verify
sudo btrfs subvolume list /mnt/pool
```

---

## Phase 3: NixOS Flake Setup [PENDING]

- [ ] Create /home/diego/mnt_git/unix/a_nixos_host/flake.nix
- [ ] Add nixos-hardware flake input (Surface support)
- [ ] Add impermanence flake input
- [ ] Create configuration.nix with:
  - [ ] Surface Pro 8 kernel (linux-surface)
  - [ ] LUKS boot configuration
  - [ ] tmpfs root + BTRFS mounts
  - [ ] Impermanence module
- [ ] Create hardware-configuration.nix
- [ ] Create modules/surface.nix (hardware tweaks)
- [ ] Create modules/desktop.nix (KDE, GNOME, Openbox)
- [ ] Create modules/containers.nix (Docker + Podman)
- [ ] Create modules/users.nix (user config)
- [ ] Create modules/impermanence.nix (persist declarations)

### Flake Structure
```
a_nixos_host/
├── flake.nix
├── flake.lock
├── configuration.nix
├── hardware-configuration.nix
└── modules/
    ├── surface.nix
    ├── desktop.nix
    ├── containers.nix
    ├── users.nix
    └── impermanence.nix
```

---

## Phase 4: Build NixOS OCI Image [PENDING]

- [ ] Install Nix on Ubuntu (if not present)
- [ ] Build NixOS system closure
- [ ] Generate OCI image from closure
- [ ] Verify image contents

### Build Commands
```bash
# Install Nix (if needed)
curl -L https://nixos.org/nix/install | sh

# Build OCI image
cd /home/diego/mnt_git/unix/a_nixos_host
nix build .#nixosConfigurations.surface.config.system.build.toplevel

# Or build OCI directly
nix build .#packages.x86_64-linux.oci-image
```

---

## Phase 5: Deploy NixOS to Subvolume [PENDING]

- [ ] Mount @root-nixos subvolume
- [ ] Create nested subvolumes for impermanence:
  - [ ] @root-nixos/nix
  - [ ] @root-nixos/persist
- [ ] Extract/copy NixOS system to @root-nixos
- [ ] Copy kernel to /boot/nixos/kernel
- [ ] Copy initrd to /boot/nixos/initrd
- [ ] Set correct permissions

### Deploy Commands
```bash
# Mount target
sudo mount -o subvol=@root-nixos /dev/mapper/pool /mnt/nixos

# Create nested subvolumes
sudo btrfs subvolume create /mnt/nixos/nix
sudo btrfs subvolume create /mnt/nixos/persist

# Extract NixOS (method depends on build output)
# Option A: From OCI image
podman load < result
podman create --name nixos-temp localhost/nixos:latest
podman export nixos-temp | sudo tar -xf - -C /mnt/nixos/nix
podman rm nixos-temp

# Option B: Direct copy from Nix store
sudo cp -a /nix/store/...-nixos-system-surface-*/* /mnt/nixos/

# Copy boot files
sudo mkdir -p /boot/nixos
sudo cp /mnt/nixos/nix/store/...-linux-*/bzImage /boot/nixos/kernel
sudo cp /mnt/nixos/nix/store/...-initrd-*/initrd /boot/nixos/initrd
```

---

## Phase 6: GRUB Configuration [PENDING]

- [ ] Create /etc/grub.d/12_nixos entry
- [ ] Create /boot/grub/update-grub.sh script
- [ ] Make script executable by both OSes
- [ ] Regenerate grub.cfg
- [ ] Test GRUB menu shows both entries

### GRUB Entry for NixOS
```bash
# /etc/grub.d/12_nixos
#!/bin/sh
exec tail -n +3 $0
# NixOS with Full Impermanence

menuentry 'NixOS (Impermanence)' --class nixos --class gnu-linux --class gnu --class os {
    insmod part_gpt
    insmod ext2
    insmod btrfs

    # Find /boot partition
    search --no-floppy --fs-uuid --set=root 0eaf7961-48c5-4b55-8a8f-04cd0b71de07

    # Load kernel - initramfs will unlock LUKS
    linux /nixos/kernel init=/nix/store/...-nixos-system-.../init root=tmpfs rd.luks.uuid=3c75c6db-4d7c-4570-81f1-02d168781aac
    initrd /nixos/initrd
}
```

### Independent GRUB Update Script
```bash
#!/bin/bash
# /boot/grub/update-grub.sh
# Regenerates GRUB config - can be called from either OS

set -e

# Ensure we're running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Generate new grub.cfg
grub-mkconfig -o /boot/grub/grub.cfg

echo "GRUB configuration updated successfully"
```

---

## Phase 7: Testing [PENDING]

- [ ] Reboot and test Kinoite boot
- [ ] Verify Kinoite mounts correct subvolumes
- [ ] Reboot and test NixOS boot
- [ ] Verify NixOS impermanence (/ is tmpfs)
- [ ] Verify NixOS /nix mount
- [ ] Verify NixOS /persist mount
- [ ] Verify NixOS /home mount
- [ ] Verify @shared accessible from both OSes
- [ ] Test KDE Plasma session
- [ ] Test GNOME session
- [ ] Test Openbox session
- [ ] Test Docker functionality
- [ ] Test Podman rootless

---

## Phase 8: Post-Install Configuration [PENDING]

- [ ] Configure Waydroid in @android
- [ ] Setup shared container storage in @shared
- [ ] Configure user dotfiles sync strategy
- [ ] Test reboot persistence (NixOS should be clean)
- [ ] Commit all configs to git
- [ ] Push to remote

---

## Phase 9: Cleanup (Optional) [FUTURE]

- [ ] Delete Ubuntu partition (nvme0n1p5)
- [ ] Expand LUKS partition to use freed space
- [ ] Grow BTRFS filesystem
- [ ] Update partition documentation

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `/boot/kinoite/vmlinuz-kinoite` | Kinoite kernel |
| `/boot/kinoite/initramfs-kinoite.img` | Kinoite initramfs |
| `/boot/nixos/kernel` | NixOS kernel |
| `/boot/nixos/initrd` | NixOS initramfs |
| `/boot/grub/grub.cfg` | GRUB configuration |
| `/boot/grub/update-grub.sh` | GRUB update script |
| `/etc/grub.d/11_kinoite` | Kinoite GRUB entry |
| `/etc/grub.d/12_nixos` | NixOS GRUB entry |

---

## Key UUIDs

| Component | UUID |
|-----------|------|
| /boot (ext4) | `0eaf7961-48c5-4b55-8a8f-04cd0b71de07` |
| LUKS partition | `3c75c6db-4d7c-4570-81f1-02d168781aac` |
| BTRFS pool | `6818afcb-97f5-43be-9436-4b9c3db98c00` |

---

## Current Status

```
Phase 1: [##########] 100% - COMPLETED
Phase 2: [          ]   0% - PENDING (next)
Phase 3: [          ]   0% - PENDING
Phase 4: [          ]   0% - PENDING
Phase 5: [          ]   0% - PENDING
Phase 6: [          ]   0% - PENDING
Phase 7: [          ]   0% - PENDING
Phase 8: [          ]   0% - PENDING
Phase 9: [          ]   0% - FUTURE
```

**Next Action**: Test Kinoite boot, then proceed with Phase 2 (Subvolume Restructure)
