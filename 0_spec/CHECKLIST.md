# Surface Pro 8 Build Checklist

> **Purpose**: Master tracking for multi-phase implementation
> **Last Updated**: 2026-01-06
> **WARNING**: DO NOT build images in Kubuntu (no disk space)
> **PREFER**: OCI container images over ISOs when available (faster deployment)

---

## PRIORITY ORDER

```
┌─────────────────────────────────────────────────────────────────┐
│  STEP 1: Create escape route (Alpine + Kali)                    │
│          ↓                                                      │
│  STEP 2: Format Kubuntu partition → becomes Windows/LUKS space  │
│          ↓                                                      │
│  STEP 3: Work from Kali to set up NixOS                        │
│          ↓                                                      │
│  STEP 4: Full system operational                                │
└─────────────────────────────────────────────────────────────────┘
```

**IMMEDIATE GOAL**: Get Alpine + Kali bootable so we can abandon Kubuntu

---

## Phase 0: ESCAPE ROUTE [PRIORITY - DO FIRST]

### Current Disk State (as of 2026-01-06)
```
nvme0n1p1   100M   EFI         /boot/efi
nvme0n1p2    16M   (reserved)
nvme0n1p3     2G   ext4        /boot
nvme0n1p4   116G   LUKS→BTRFS  /mnt (pool)    ← KEEP THIS
nvme0n1p5   118G   ext4        / (Kubuntu)    ← RECLAIM THIS
```
- [x] Disk state checked
- [ ] Backup critical data from Kubuntu to external/cloud

### Step 0.1: Prepare USB Boot Media
**Must boot from USB to repartition - can't do it live**

**PREFER OCI IMAGES** - They are faster to deploy than ISOs when available

**Already have:**
- [x] Alpine ISO: `/home/diego/alpine-official.iso` (994M) - USB recovery only
- [x] Kali ISO: `/home/diego/kali-installer.iso` (4.5G)
- [x] NixOS Plasma: `/home/diego/nixos-plasma.iso` (3.2G)

**Still need:**
- [ ] Download Arch Linux ISO: https://archlinux.org/download/
      - ~800MB, rolling release
      - Need USB keyboard during install (Surface keyboard works AFTER linux-surface installed)

**USB Setup:**
- [ ] Create bootable USB with Ventoy
- [ ] Add Kali ISO to Ventoy USB
- [ ] Add Alpine ISO to Ventoy USB (backup)
- [ ] TEST: Can boot Kali from USB

### Step 0.2: Repartition from Kali Live USB
**Boot from USB, then shrink Kubuntu**
- [ ] Boot Kali Live USB
- [ ] Open GParted (included in Kali)
- [ ] Shrink nvme0n1p5 (Kubuntu) from 118G → ~70G
      - This frees ~48G for Alpine + Kali + spare
- [ ] Create new partitions:
      - [ ] nvme0n1p6: 5GB ext4 (Alpine)
      - [ ] nvme0n1p7: 25GB ext4 (Kali) ← larger for full desktop
- [ ] Apply changes
- [ ] Reboot to verify Kubuntu still works

### Step 0.3: Install Arch Linux + linux-surface (5GB)
**Why Arch instead of Alpine?** Surface Pro keyboard needs linux-surface drivers. Alpine doesn't have them. Arch has official linux-surface repo.

- [ ] Boot Arch ISO from USB (need USB keyboard initially)
- [ ] Connect to WiFi: `iwctl station wlan0 connect "SSID"`
- [ ] Mount: `mount /dev/nvme0n1p6 /mnt`
- [ ] Install base:
      ```bash
      pacstrap -K /mnt base linux linux-firmware \
          networkmanager vim sudo cryptsetup btrfs-progs openssh curl wget git
      genfstab -U /mnt >> /mnt/etc/fstab
      ```
- [ ] Chroot and configure:
      ```bash
      arch-chroot /mnt
      # Set root password: 1234567890
      # Create user with sudo
      ```
- [ ] Add linux-surface repo to /etc/pacman.conf:
      ```bash
      [linux-surface]
      Server = https://pkg.surfacelinux.com/arch/
      ```
- [ ] Install Surface kernel:
      ```bash
      pacman-key --recv-keys 56C464BAAC421453
      pacman-key --lsign-key 56C464BAAC421453
      pacman -Syu linux-surface linux-surface-headers iptsd
      systemctl enable iptsd NetworkManager sshd
      ```
- [ ] Install bootloader (systemd-boot)
- [ ] Reboot and test Surface keyboard works
- [ ] Install Node.js + Claude CLI:
      ```bash
      sudo pacman -S nodejs npm
      sudo npm install -g @anthropic-ai/claude-code
      ```
- [ ] TEST: Can boot into Arch
- [ ] TEST: Surface keyboard works!
- [ ] TEST: Can unlock LUKS from Arch
- [ ] TEST: `claude` command works

**Full guide**: See `/home/diego/mnt_git/unix/a_arch-surface_fallback_desk/SETUP.md`

### Step 0.4: Install Kali Linux (25GB) - WITH DESKTOP
- [ ] Boot Kali Live USB
- [ ] Run Kali installer
- [ ] Target: nvme0n1p7 (25GB partition)
- [ ] Select desktop: **XFCE** (default) or **KDE** (heavier but nicer)
- [ ] Install Surface drivers post-install:
      ```bash
      # Add linux-surface repo
      wget -qO - https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc | sudo apt-key add -
      echo "deb https://pkg.surfacelinux.com/debian release main" | sudo tee /etc/apt/sources.list.d/linux-surface.list
      sudo apt update
      sudo apt install linux-image-surface linux-headers-surface iptsd
      ```
- [ ] Install Node.js (for Claude):
      ```bash
      curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
      sudo apt install -y nodejs
      ```
- [ ] Install Claude Code CLI:
      ```bash
      sudo npm install -g @anthropic-ai/claude-code
      # Set API key in ~/.bashrc or ~/.zshrc
      echo 'export ANTHROPIC_API_KEY="sk-..."' >> ~/.bashrc
      ```
- [ ] Configure WiFi
- [ ] Add boot entry to GRUB
- [ ] TEST: Can boot Kali with full GUI desktop
- [ ] TEST: Browser works, terminal works
- [ ] TEST: `node --version` works
- [ ] TEST: `claude` command works

### Step 0.5: Verify Escape Route
- [ ] Can boot Arch from systemd-boot/GRUB menu
- [ ] Can boot Kali from GRUB menu
- [ ] **Surface keyboard works in Arch**
- [ ] Kali has full XFCE/KDE desktop working
- [ ] Both have network access (WiFi or ethernet)
- [ ] Can unlock LUKS from Arch (cryptsetup open)
- [ ] Can browse web from Kali

**CHECKPOINT: Once verified, Kubuntu can be DELETED entirely**

---

## KUBUNTU STAYS UNTIL THE END

Kubuntu is our safety net. Only delete AFTER:
- Arch boots with Surface keyboard working
- Kali boots with full desktop
- Both have Node.js + Claude working
- Network works on both

---

### Step 0.6: Reclaim Kubuntu Space (FINAL STEP - LAST)
- [ ] Boot into Kali (installed, not USB)
- [ ] Delete nvme0n1p5 (old Kubuntu) with GParted
- [ ] Decide what to do with ~70G freed space:
      - Option A: Expand LUKS partition
      - Option B: Create Windows partition (~20G)
      - Option C: Leave for later

---

## Phase 1: Documentation [90% COMPLETE]

- [x] Rewrite ARCHITECTURE.md
- [x] Create DISK_LAYOUT.md
- [x] Create ISOLATION_LAYERS.md
- [x] Create PERSONAL_SPACE.md
- [x] Rewrite ROADMAP.md
- [x] Archive HANDOFF.md to z_archive/
- [x] Update a_nixos_host/0_spec/architecture.md
- [x] Update a_nixos_host/0_spec/runbook.md
- [x] Create a_win11_webcam/SETUP.md
- [x] Create a_kali_security/SETUP.md
- [ ] Final review of all docs for consistency

---

## Phase 2: Subvolume Migration [0%]

**Prerequisites:**
- [ ] Full backup of existing data to external drive
- [ ] Boot media ready (Alpine USB or NixOS live)
- [ ] LUKS password confirmed working

**Tasks:**
- [ ] Boot into recovery environment
- [ ] Unlock LUKS: `cryptsetup open /dev/nvme0n1p6 pool`
- [ ] Backup current subvolumes:
  - [ ] `btrfs send @root-nixos > /backup/root-nixos.btrfs`
  - [ ] `btrfs send @home-nixos > /backup/home-nixos.btrfs`
- [ ] Create new structure:
  - [ ] `btrfs subvolume create @system`
  - [ ] `btrfs subvolume create @system/nix`
  - [ ] `btrfs subvolume create @system/state`
  - [ ] `btrfs subvolume create @system/logs`
  - [ ] `btrfs subvolume create @user`
  - [ ] `btrfs subvolume create @user/home`
  - [ ] `btrfs subvolume create @shared`
  - [ ] `btrfs subvolume create @shared/containers`
  - [ ] `btrfs subvolume create @shared/flatpak`
  - [ ] `btrfs subvolume create @shared/microvm`
  - [ ] `btrfs subvolume create @shared/waydroid`
- [ ] Migrate data with reflinks
- [ ] Verify all data migrated
- [ ] Delete old subvolumes (after verification)
- [ ] Verify `btrfs subvolume list` shows new structure

---

## Phase 3: NixOS Configuration [0%]

**hardware-configuration.nix:**
- [ ] Update /nix mount: `subvol=@system/nix`
- [ ] Add /var/lib mount: `subvol=@system/state`
- [ ] Add /var/log mount: `subvol=@system/logs`
- [ ] Update /home mount: `subvol=@user/home`
- [ ] Add /var/lib/containers: `subvol=@shared/containers`
- [ ] Add /var/lib/flatpak: `subvol=@shared/flatpak`
- [ ] Add /var/lib/microvms: `subvol=@shared/microvm`
- [ ] Add /var/lib/waydroid: `subvol=@shared/waydroid`
- [ ] Replace file swap with zram
- [ ] Update LUKS partition to nvme0n1p6

**configuration.nix:**
- [ ] Add microvm.nix flake input
- [ ] Enable microvm.host
- [ ] Add Distrobox package
- [ ] Add Tomb and age packages
- [ ] Enable thermald service
- [ ] Configure SDDM sessions:
  - [ ] KDE Plasma 6 (Wayland, default)
  - [ ] GNOME (Wayland)
  - [ ] Waydroid session (cage + waydroid)
  - [ ] Openbox (X11)
  - [ ] Brave Kiosk (cage + brave --kiosk)
- [ ] Update persistence declarations:
  - [ ] Add `.var` directory
  - [ ] Add `.local/share/fish/fish_history`
  - [ ] Add `vault.tomb` file

**Build & Test:**
- [ ] `nix flake check` passes
- [ ] `nixos-rebuild build --flake .#surface` succeeds
- [ ] `nixos-rebuild switch --flake .#surface` succeeds
- [ ] Reboot successful
- [ ] All mounts correct (`mount | grep btrfs`)
- [ ] Zram active (`swapon --show`)
- [ ] Thermald running

---

## Phase 4: Arch Linux Recovery [MOVED TO PHASE 0]

**NOTE**: Arch Linux with linux-surface replaces Alpine as fallback OS.
Alpine moved to USB-only recovery (see `a_alpine_fallback_usb/`).

- [x] Partition created: nvme0n1p6 (5GB)
- [ ] Install Arch + linux-surface (see Step 0.3)
- [ ] Surface keyboard works
- [ ] Can unlock LUKS
- [ ] Can mount BTRFS subvolumes
- [ ] Node.js + Claude CLI work

---

## Phase 4b: Kali Linux [0%]

- [ ] Create ~20GB partition (nvme0n1p4)
- [ ] Download Kali installer ISO
- [ ] Install Kali (full or minimal)
- [ ] Install Surface drivers (linux-surface)
- [ ] Configure network
- [ ] Verify security tools work
- [ ] Add boot entry to rEFInd
- [ ] Test: boots from menu
- [ ] Test: nmap, burpsuite work
- [ ] Test: isolated from LUKS partition

---

## Phase 5: Windows 11 Webcam [0%]

- [ ] Create ~20GB partition (nvme0n1p5)
- [ ] Install Windows 11 (no MS account)
- [ ] Debloat: remove apps, disable telemetry
- [ ] Install Surface webcam drivers
- [ ] Install OBS Studio
- [ ] Configure RTSP/NDI streaming
- [ ] Add boot entry
- [ ] Test: webcam works in Windows
- [ ] Test: NixOS receives stream via v4l2loopback

---

## Phase 6: Vault Configuration [0%]

- [ ] Create tomb: `tomb dig -s 2048 ~/vault.tomb`
- [ ] Create key on USB: `tomb forge /usb/.vault/vault.key`
- [ ] Lock tomb with key
- [ ] Create vault directory structure
- [ ] Migrate secrets:
  - [ ] SSH keys
  - [ ] API tokens
  - [ ] Password database
  - [ ] 2FA recovery codes
- [ ] Create unlock script
- [ ] Test open/close cycle
- [ ] Test survives reboot
- [ ] Backup vault to cloud

---

## Phase 7: Final Testing [0%]

**Boot Scenarios:**
- [ ] NixOS with USB key (auto-unlock)
- [ ] NixOS without USB (password prompt)
- [ ] Arch Linux recovery (Surface keyboard works!)
- [ ] Kali Linux
- [ ] Windows 11

**Desktop Sessions:**
- [ ] KDE Plasma (Wayland)
- [ ] GNOME (Wayland)
- [ ] Openbox (X11)
- [ ] Waydroid (Android)
- [ ] Brave Kiosk

**Container Runtimes:**
- [ ] Podman rootless
- [ ] Distrobox
- [ ] Flatpak
- [ ] microvm.nix

**Security:**
- [ ] LUKS encryption verified
- [ ] Vault double-encryption verified
- [ ] Kali isolated from encrypted data

---

## Critical Reminders

1. **NO BUILDS IN KUBUNTU** - No disk space
2. **Backup before Phase 2** - Subvolume migration is destructive
3. **Test each phase** before proceeding to next
4. **Keep Arch working** - It's your recovery lifeline (has Surface keyboard support!)
5. **Alpine is USB-only** - For emergency recovery when nothing else works
6. **Document any deviations** from this plan

---

## Progress Summary

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 0: Escape Route | 30% | Partitions ready, need Arch + Kali install |
| Phase 1: Documentation | 90% | Final review pending |
| Phase 2: Subvolumes | 0% | Needs backup first |
| Phase 3: NixOS Config | 0% | After Phase 2 |
| Phase 4: Arch Recovery | 30% | Partition ready, install pending |
| Phase 4b: Kali | 0% | Partition ready, install pending |
| Phase 5: Windows | 0% | Can do independently |
| Phase 6: Vault | 0% | After Phase 3 |
| Phase 7: Testing | 0% | After all phases |

**Alpine**: Moved to USB-only recovery (`a_alpine_fallback_usb/`)
