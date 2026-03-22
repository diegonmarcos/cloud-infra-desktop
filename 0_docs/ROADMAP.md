# Implementation Roadmap

> **Status**: Phase 1 In Progress
> **Last Updated**: 2026-01-06

---

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         IMPLEMENTATION PHASES                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Phase 1        Phase 2         Phase 3         Phase 4         Phase 4b   │
│  DOCS           SUBVOLUMES      NIXOS           ALPINE          KALI       │
│  ████████░░     ░░░░░░░░░░      ░░░░░░░░░░      ░░░░░░░░░░      ░░░░░░░░░░ │
│  80%            0%              0%              0%              0%         │
│                                                                             │
│  Phase 5        Phase 6         Phase 7                                     │
│  WINDOWS        VAULT           TESTING                                     │
│  ░░░░░░░░░░     ░░░░░░░░░░      ░░░░░░░░░░                                  │
│  0%             0%              0%                                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: Documentation [IN PROGRESS]

**Goal**: Complete architecture documentation before implementation

### Tasks

- [x] Rewrite ARCHITECTURE.md with new design
- [x] Create DISK_LAYOUT.md specification
- [x] Create ISOLATION_LAYERS.md specification
- [x] Create PERSONAL_SPACE.md specification
- [x] Rewrite ROADMAP.md (this file)
- [ ] Archive HANDOFF.md to z_archive/
- [ ] Update a_nixos_host/0_spec/architecture.md
- [ ] Update a_nixos_host/0_spec/runbook.md
- [ ] Create a_win11_webcam/SETUP.md

### Deliverables

| File | Status | Description |
|------|--------|-------------|
| `0_spec/ARCHITECTURE.md` | DONE | Main architecture overview |
| `0_spec/DISK_LAYOUT.md` | DONE | Partition and subvolume spec |
| `0_spec/ISOLATION_LAYERS.md` | DONE | Security zones and sandboxing |
| `0_spec/PERSONAL_SPACE.md` | DONE | User space organization |
| `0_spec/ROADMAP.md` | DONE | This implementation checklist |
| `z_archive/HANDOFF.md` | PENDING | Archive obsolete design |
| `a_nixos_host/0_spec/*` | PENDING | NixOS-specific docs |
| `a_win11_webcam/SETUP.md` | PENDING | Windows 11 setup guide |

---

## Phase 2: Subvolume Migration [PENDING]

**Goal**: Restructure BTRFS subvolumes with semantic naming

### Prerequisites

- [ ] Full backup of existing data
- [ ] Boot into Alpine recovery or live USB
- [ ] Verify LUKS can be unlocked

### Tasks

```bash
# 1. Backup current data
sudo btrfs send @root-nixos > /backup/root-nixos.btrfs
sudo btrfs send @home-nixos > /backup/home-nixos.btrfs

# 2. Create new subvolume structure
sudo btrfs subvolume create @system
sudo btrfs subvolume create @system/nix
sudo btrfs subvolume create @system/state
sudo btrfs subvolume create @system/logs

sudo btrfs subvolume create @user
sudo btrfs subvolume create @user/home

sudo btrfs subvolume create @shared
sudo btrfs subvolume create @shared/containers
sudo btrfs subvolume create @shared/flatpak
sudo btrfs subvolume create @shared/microvm
sudo btrfs subvolume create @shared/waydroid

# 3. Migrate data
sudo cp -a @root-nixos/nix/* @system/nix/
sudo cp -a @root-nixos/persist/* @system/state/
sudo cp -a @home-nixos/* @user/home/

# 4. Delete old subvolumes (after verification)
sudo btrfs subvolume delete @root-nixos
sudo btrfs subvolume delete @home-nixos
sudo btrfs subvolume delete @root-kinoite  # If exists
sudo btrfs subvolume delete @home-kinoite  # If exists
```

### Verification Checklist

- [ ] All data migrated successfully
- [ ] Subvolume permissions correct (755)
- [ ] Old subvolumes deleted
- [ ] `btrfs subvolume list` shows new structure

---

## Phase 3: NixOS Configuration Update [PENDING]

**Goal**: Update NixOS configs for new subvolumes and features

### Tasks

#### hardware-configuration.nix

- [ ] Update /nix mount: `subvol=@system/nix`
- [ ] Add /var/lib mount: `subvol=@system/state`
- [ ] Add /var/log mount: `subvol=@system/logs`
- [ ] Update /home mount: `subvol=@user/home`
- [ ] Add container mounts: `@shared/containers`, `@shared/flatpak`, `@shared/microvm`
- [ ] Replace file swap with zram
- [ ] Verify LUKS configuration intact

#### configuration.nix

- [ ] Add microvm.nix flake input
- [ ] Enable microvm.host and define sandbox VMs
- [ ] Add Distrobox package
- [ ] Add Tomb and age packages
- [ ] Enable thermald service
- [ ] Configure SDDM sessions:
  - [ ] KDE Plasma 6 (Wayland, default)
  - [ ] GNOME (Wayland)
  - [ ] Waydroid standalone session (cage + waydroid)
  - [ ] Openbox (X11, lightweight)
  - [ ] Brave Kiosk session (cage + brave --kiosk)
- [ ] Update persistence declarations:
  - [ ] Add `.var` directory
  - [ ] Add `.local/share/fish/fish_history`
  - [ ] Add `vault.tomb` file
- [ ] Remove container directories from persistence (now subvolumes)

### Build and Test

```bash
# Check configuration
nix flake check

# Build without switching
nixos-rebuild build --flake .#surface

# Test in VM (if possible)
nixos-rebuild build-vm --flake .#surface

# Switch (after subvolume migration)
sudo nixos-rebuild switch --flake .#surface
```

### Verification Checklist

- [ ] System boots successfully
- [ ] All mounts correct (`mount | grep btrfs`)
- [ ] Zram swap active (`swapon --show`)
- [ ] Thermald running (`systemctl status thermald`)
- [ ] microvm.nix available (`systemctl list-units microvm@*`)
- [ ] Persistence working (reboot and verify)

---

## Phase 4: Alpine Recovery Setup [PENDING]

**Goal**: Install Alpine recovery OS on unencrypted partition

### Tasks

- [ ] Create 5GB partition for Alpine (nvme0n1p3)
- [ ] Build Alpine ISO using `a_alpine_fallback/build.sh`
- [ ] Install Alpine to partition
- [ ] Configure network (DHCP + WiFi)
- [ ] Install recovery tools:
  - [ ] cryptsetup
  - [ ] btrfs-progs
  - [ ] e2fsprogs
  - [ ] openssh
  - [ ] vim
- [ ] Add boot entry to rEFInd/GRUB
- [ ] Test recovery procedures

### Boot Entry

```bash
# /boot/efi/EFI/refind/refind.conf addition
menuentry "Alpine Recovery" {
    icon     /EFI/refind/icons/os_linux.png
    volume   "Alpine"
    loader   /boot/vmlinuz-lts
    initrd   /boot/initramfs-lts
    options  "root=/dev/nvme0n1p3 modules=sd-mod,usb-storage,ext4"
}
```

### Verification Checklist

- [ ] Alpine boots from menu
- [ ] Network connectivity works
- [ ] Can unlock LUKS manually
- [ ] Can mount BTRFS subvolumes
- [ ] SSH access works

---

## Phase 4b: Kali Linux Security Setup [PENDING]

**Goal**: Install Kali Linux for penetration testing and security auditing

### Tasks

- [ ] Create ~20GB partition for Kali (nvme0n1p4)
- [ ] Install Kali Linux (full or minimal)
- [ ] Configure network (DHCP + WiFi)
- [ ] Install essential security tools:
  - [ ] nmap, masscan (network scanning)
  - [ ] burpsuite, zap (web testing)
  - [ ] metasploit (exploitation framework)
  - [ ] wireshark (packet analysis)
  - [ ] john, hashcat (password cracking)
  - [ ] aircrack-ng (wireless)
- [ ] Configure isolated network namespace
- [ ] Add boot entry to rEFInd/GRUB
- [ ] Test security workflows

### Boot Entry

```bash
# /boot/efi/EFI/refind/refind.conf addition
menuentry "Kali Linux" {
    icon     /EFI/refind/icons/os_kali.png
    volume   "Kali"
    loader   /boot/vmlinuz-*
    initrd   /boot/initrd.img-*
    options  "root=/dev/nvme0n1p4 ro quiet"
}
```

### Verification Checklist

- [ ] Kali boots from menu
- [ ] Network connectivity works
- [ ] Security tools launch correctly
- [ ] WiFi adapter recognized (monitor mode if supported)
- [ ] Isolated from NixOS LUKS partition

---

## Phase 5: Windows 11 Webcam Setup [PENDING]

**Goal**: Minimal Windows 11 for Surface webcam driver compatibility

### Tasks

- [ ] Create ~20GB partition for Windows (nvme0n1p5)
- [ ] Install Windows 11 (minimal, no MS account)
- [ ] Debloat Windows:
  - [ ] Remove preinstalled apps
  - [ ] Disable Cortana, telemetry
  - [ ] Disable Windows Update (or limit)
  - [ ] Disable Defender real-time (optional)
- [ ] Install Surface webcam drivers
- [ ] Install OBS Studio for virtual camera
- [ ] Configure network streaming (NDI/MJPEG)
- [ ] Add boot entry
- [ ] Document webcam piping to NixOS

### Webcam Streaming Options

| Method | Latency | Complexity | NixOS Package |
|--------|---------|------------|---------------|
| NDI | Low | Medium | ndi-sdk |
| RTSP | Medium | Low | ffmpeg |
| MJPEG over HTTP | Medium | Low | curl + v4l2loopback |
| USB/IP | Low | High | usbip |

### Verification Checklist

- [ ] Windows 11 boots
- [ ] Webcam works in Windows
- [ ] Streaming to network works
- [ ] NixOS can receive stream
- [ ] v4l2loopback creates virtual device

---

## Phase 6: Vault Configuration [PENDING]

**Goal**: Set up Tomb vault for secrets with USB key

### Tasks

- [ ] Create tomb file: `tomb dig -s 2048 ~/vault.tomb`
- [ ] Create key on USB: `tomb forge /usb-key/.vault/vault.key`
- [ ] Lock tomb: `tomb lock ~/vault.tomb -k /usb-key/.vault/vault.key`
- [ ] Create vault directory structure
- [ ] Migrate secrets to vault:
  - [ ] SSH keys
  - [ ] API tokens
  - [ ] Password database
  - [ ] 2FA recovery codes
- [ ] Create unlock script
- [ ] Configure SSH agent integration
- [ ] Test open/close cycle
- [ ] Backup vault to cloud

### Vault Structure

```
~/vault/
├── keys/
│   ├── ssh/
│   ├── gpg/
│   └── api/
├── secrets/
│   ├── passwords.kdbx
│   └── 2fa-recovery/
└── documents/
    ├── identity/
    └── financial/
```

### Verification Checklist

- [ ] Tomb opens with USB key
- [ ] Tomb opens with password fallback
- [ ] SSH keys load to agent
- [ ] Tomb closes cleanly
- [ ] Vault survives reboot (file persisted)
- [ ] Backup to cloud works

---

## Phase 7: Final Testing [PENDING]

**Goal**: Comprehensive testing of all components

### Boot Scenarios

- [ ] Normal boot with USB key (auto-unlock)
- [ ] Normal boot without USB (password prompt)
- [ ] Boot to Alpine recovery
- [ ] Boot to Kali Linux
- [ ] Boot to Windows 11
- [ ] Boot after power failure (filesystem integrity)

### Desktop Sessions

- [ ] KDE Plasma (Wayland) - default
- [ ] KDE Plasma (X11) - fallback
- [ ] GNOME (Wayland)
- [ ] Openbox (X11)
- [ ] Waydroid (Android)
- [ ] Custom kiosk sessions

### Container Runtimes

- [ ] Podman rootless containers
- [ ] Docker compatibility
- [ ] Distrobox containers
- [ ] Flatpak applications
- [ ] microvm.nix VMs (isolated)

### Persistence

- [ ] System state survives reboot
- [ ] User configs survive reboot
- [ ] Container data survives reboot
- [ ] Flatpak apps survive reboot
- [ ] Vault file survives reboot

### Security

- [ ] LUKS encryption verified
- [ ] Vault double-encryption verified
- [ ] Flatpak sandboxing verified
- [ ] microvm.nix isolation verified
- [ ] SSH keys protected

### Kali Linux

- [ ] Kali boots and reaches desktop
- [ ] Network scanning tools work (nmap, masscan)
- [ ] Web testing tools work (burpsuite, zap)
- [ ] WiFi adapter recognized
- [ ] Isolated from NixOS encrypted partition
- [ ] No access to LUKS data from Kali

---

## Key UUIDs Reference

| Component | UUID |
|-----------|------|
| EFI Partition | `2CE0-6722` |
| /boot Partition | `0eaf7961-48c5-4b55-8a8f-04cd0b71de07` |
| LUKS Partition | `3c75c6db-4d7c-4570-81f1-02d168781aac` |
| USB Keyfile (Ventoy) | `223C-F3F8` |

---

## Rollback Procedures

### NixOS Generation Rollback

```bash
# List generations
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

# Rollback to previous
sudo nixos-rebuild switch --rollback

# Boot to specific generation
# Select from GRUB menu at boot
```

### BTRFS Snapshot Rollback

```bash
# Create snapshot before changes
sudo btrfs subvolume snapshot @system/nix @system/nix-backup-$(date +%Y%m%d)

# Rollback by renaming
sudo btrfs subvolume delete @system/nix
sudo btrfs subvolume snapshot @system/nix-backup-20260106 @system/nix
```

### Full Recovery

1. Boot Alpine recovery
2. Unlock LUKS
3. Mount subvolumes
4. Restore from backup
5. Rebuild GRUB
6. Reboot

---

## Progress Summary

| Phase | Status | Completion |
|-------|--------|------------|
| Phase 1: Documentation | IN PROGRESS | 90% |
| Phase 2: Subvolume Migration | PENDING | 0% |
| Phase 3: NixOS Config | PENDING | 0% |
| Phase 4: Alpine Recovery | PENDING | 0% |
| Phase 4b: Kali Security | PENDING | 0% |
| Phase 5: Windows 11 | PENDING | 0% |
| Phase 6: Vault | PENDING | 0% |
| Phase 7: Testing | PENDING | 0% |

**Next Action**: Complete Phase 1 documentation (create a_kali_security/SETUP.md), then proceed to Phase 2.
