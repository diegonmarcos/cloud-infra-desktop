# Disk Layout Specification

> **Device**: Surface Pro 8 (256GB NVMe)
> **Encryption**: LUKS2 with USB keyfile + password fallback
> **Filesystem**: BTRFS with semantic subvolume organization
> **Unencrypted OSes**: Alpine (recovery), Kali (security), Windows 11 (webcam)

---

## Partition Table (GPT)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           NVMe 256GB PARTITION LAYOUT                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                     NON-ENCRYPTED (~50GB)                           │   │
│  │                                                                     │   │
│  │  nvme0n1p1    100MB   EFI System     FAT32     /boot/efi           │   │
│  │  nvme0n1p2    2GB     Boot           ext4      /boot               │   │
│  │  nvme0n1p3    5GB     Alpine         ext4      /recovery           │   │
│  │  nvme0n1p4    ~20GB   Kali Linux     ext4      (pentesting)        │   │
│  │  nvme0n1p5    ~20GB   Windows 11     NTFS      (webcam driver)     │   │
│  │                                                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      LUKS ENCRYPTED (~180GB)                        │   │
│  │                                                                     │   │
│  │  nvme0n1p6    ~180GB  LUKS2 → BTRFS  /dev/mapper/pool              │   │
│  │                                                                     │   │
│  │  Unlock methods:                                                    │   │
│  │    1. USB keyfile (automatic): /usb-key/.luks/surface.key          │   │
│  │    2. Password (fallback): prompted if USB not found               │   │
│  │                                                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Partition Details

| Partition | Size | Type | UUID | Mount Point | Purpose |
|-----------|------|------|------|-------------|---------|
| nvme0n1p1 | 100MB | FAT32 | `2CE0-6722` | /boot/efi | EFI System Partition |
| nvme0n1p2 | 2GB | ext4 | `0eaf7961-48c5-4b55-8a8f-04cd0b71de07` | /boot | Kernels, initrd |
| nvme0n1p3 | 5GB | ext4 | (TBD) | /recovery | Alpine recovery OS |
| nvme0n1p4 | ~20GB | ext4 | (TBD) | - | Kali Linux (pentesting) |
| nvme0n1p5 | ~20GB | NTFS | (TBD) | - | Windows 11 webcam |
| nvme0n1p6 | ~180GB | LUKS2 | `3c75c6db-4d7c-4570-81f1-02d168781aac` | /dev/mapper/pool | Encrypted pool |

---

## BTRFS Subvolume Structure

```
/dev/mapper/pool (BTRFS, zstd compression)
│
├── @system/                    ═══════════════════════════════════════════
│   │                           SYSTEM STATE (OS-managed, declarative)
│   │
│   ├── nix/                    → /nix
│   │   │                       Nix store (immutable packages)
│   │   │                       Size: ~30-50GB
│   │   │                       Mount: neededForBoot = true
│   │   │
│   │   └── store/              Read-only derivations
│   │       var/nix/            Nix daemon state
│   │
│   ├── state/                  → /var/lib (via impermanence bind)
│   │   │                       System persistent state
│   │   │                       Size: ~5-10GB
│   │   │
│   │   ├── nixos/              NixOS state
│   │   ├── systemd/            systemd machine state
│   │   ├── bluetooth/          Bluetooth pairings
│   │   └── NetworkManager/     Network connections
│   │
│   └── logs/                   → /var/log (via impermanence bind)
│                               System logs
│                               Size: ~2-5GB
│
├── @user/                      ═══════════════════════════════════════════
│   │                           USER DATA (personal, persistent)
│   │
│   ├── home/                   → /home/user
│   │   │                       User home directory
│   │   │                       Size: ~20-50GB
│   │   │
│   │   ├── .config/            App configurations
│   │   ├── .local/             Local data + binaries
│   │   ├── .cache/             Caches (can be cleared)
│   │   ├── .ssh/               SSH keys and config
│   │   ├── .gnupg/             GPG keys
│   │   ├── .var/               Flatpak user data
│   │   ├── Documents/          Personal documents
│   │   ├── Downloads/          Downloaded files
│   │   ├── Projects/           Development projects
│   │   └── vault.tomb          Encrypted secrets container
│   │
│   └── vault/                  → ~/vault (mount point when open)
│                               LUKS-in-LUKS encrypted secrets
│                               Size: ~1-5GB
│                               Unlock: separate key on USB
│
└── @shared/                    ═══════════════════════════════════════════
    │                           SHARED RESOURCES (containers, apps)
    │
    ├── containers/             → /var/lib/containers
    │   │                       Podman/Docker storage
    │   │                       Size: ~30-50GB
    │   │
    │   ├── storage/            Container images + layers
    │   └── volumes/            Persistent volumes
    │
    ├── flatpak/                → /var/lib/flatpak
    │   │                       Flatpak apps and runtimes
    │   │                       Size: ~10-20GB
    │   │
    │   ├── app/                Installed applications
    │   └── runtime/            Shared runtimes
    │
    ├── microvm/                   → /var/lib/microvms
    │   │                       microvm.nix VM storage
    │   │                       Size: ~10-20GB
    │   │
    │   ├── vm/                 VM images
    │   └── cache/              Runtime cache
    │
    └── waydroid/               → /var/lib/waydroid
                                Android container storage
                                Size: ~5-10GB
```

---

## NixOS Mount Configuration

### Root (tmpfs)

```nix
fileSystems."/" = {
  device = "none";
  fsType = "tmpfs";
  options = [ "defaults" "size=2G" "mode=755" ];
};
```

### System Subvolumes

```nix
fileSystems."/nix" = {
  device = "/dev/mapper/pool";
  fsType = "btrfs";
  options = [ "subvol=@system/nix" "compress=zstd" "noatime" ];
  neededForBoot = true;
};

# Note: /var/lib and /var/log are handled via impermanence
# They bind-mount from /persist which points to @system/state
```

### User Subvolumes

```nix
fileSystems."/home" = {
  device = "/dev/mapper/pool";
  fsType = "btrfs";
  options = [ "subvol=@user/home" "compress=zstd" "noatime" ];
};

# vault.tomb is a file inside /home/user, mounted manually
```

### Shared Subvolumes

```nix
fileSystems."/var/lib/containers" = {
  device = "/dev/mapper/pool";
  fsType = "btrfs";
  options = [ "subvol=@shared/containers" "compress=zstd" "noatime" ];
};

fileSystems."/var/lib/flatpak" = {
  device = "/dev/mapper/pool";
  fsType = "btrfs";
  options = [ "subvol=@shared/flatpak" "compress=zstd" "noatime" ];
};

fileSystems."/var/lib/microvms" = {
  device = "/dev/mapper/pool";
  fsType = "btrfs";
  options = [ "subvol=@shared/microvm" "compress=zstd" "noatime" ];
};

fileSystems."/var/lib/waydroid" = {
  device = "/dev/mapper/pool";
  fsType = "btrfs";
  options = [ "subvol=@shared/waydroid" "compress=zstd" "noatime" ];
};
```

### Boot Partitions

```nix
fileSystems."/boot" = {
  device = "/dev/disk/by-uuid/0eaf7961-48c5-4b55-8a8f-04cd0b71de07";
  fsType = "ext4";
};

fileSystems."/boot/efi" = {
  device = "/dev/disk/by-uuid/2CE0-6722";
  fsType = "vfat";
  options = [ "umask=0077" ];
};
```

---

## Swap Configuration (Zram)

```nix
# Use zram instead of file-based swap
# More efficient on SSD, better for 8GB RAM system

zramSwap = {
  enable = true;
  memoryPercent = 50;  # 4GB compressed swap
  algorithm = "zstd";
};

# Remove file-based swap
swapDevices = [];
```

---

## LUKS Configuration

### Key Hierarchy

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              KEY MANAGEMENT                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  USB KEY (Ventoy - UUID: 223C-F3F8)                                        │
│  ├── VTOYEFI/.luks/surface.key     → LUKS keyfile (4096 bytes)            │
│  └── VTOYEFI/.vault/vault.key      → Tomb keyfile (optional)               │
│                                                                             │
│  LUKS Keyslots:                                                            │
│  ├── Slot 0: Password (1234567890) - CHANGE AFTER SETUP                    │
│  └── Slot 1: USB keyfile                                                    │
│                                                                             │
│  Boot Unlock Flow:                                                          │
│  1. initrd searches for USB (5 second timeout)                             │
│  2. If USB found → mount VTOYEFI, read keyfile, unlock                     │
│  3. If USB not found → prompt for password                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### initrd LUKS Configuration

```nix
boot.initrd.luks.devices."pool" = {
  device = "/dev/disk/by-uuid/3c75c6db-4d7c-4570-81f1-02d168781aac";
  preLVM = true;
  allowDiscards = true;

  # USB keyfile
  keyFile = "/usb-key/.luks/surface.key";
  keyFileSize = 4096;
  keyFileTimeout = 5;
  fallbackToPassword = true;

  preOpenCommands = ''
    echo "[USB-KEY] Searching for USB keyfile..."
    mkdir -p /usb-key
    # ... (mount USB, check for keyfile)
  '';

  postOpenCommands = ''
    umount /usb-key 2>/dev/null || true
  '';
};
```

---

## Storage Budget

| Component | Min Size | Max Size | Notes |
|-----------|----------|----------|-------|
| **NON-ENCRYPTED** | | | |
| EFI | 100MB | 100MB | Fixed |
| /boot | 2GB | 2GB | Kernels, initrd |
| Alpine | 5GB | 5GB | Recovery OS |
| Kali Linux | 15GB | 25GB | Pentesting, security tools |
| Windows 11 | 15GB | 25GB | Debloated, webcam only |
| **LUKS ENCRYPTED** | | | |
| @system/nix | 25GB | 40GB | Nix store |
| @system/state | 5GB | 10GB | System state |
| @system/logs | 2GB | 5GB | Logs |
| @user/home | 15GB | 40GB | User data |
| @user/vault | 1GB | 5GB | Secrets |
| @shared/containers | 15GB | 30GB | Podman |
| @shared/flatpak | 10GB | 15GB | Flatpak apps |
| @shared/microvm | 10GB | 15GB | microvm.nix VMs |
| @shared/waydroid | 5GB | 10GB | Android |
| **TOTAL** | ~125GB | ~252GB | |

---

## Subvolume Creation Commands

```bash
# From recovery or live USB with LUKS open

# Mount pool
mount /dev/mapper/pool /mnt

# Create semantic structure
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

# Set permissions
chmod 755 /mnt/@system /mnt/@user /mnt/@shared

# Verify
btrfs subvolume list /mnt
```

---

## Migration from Old Layout

```bash
# OLD structure → NEW structure mapping
@root-nixos/nix     → @system/nix
@root-nixos/persist → @system/state (split logs separately)
@home-nixos         → @user/home
@shared             → @shared/containers (split by purpose)
@android            → @shared/waydroid
```

See [ROADMAP.md](./ROADMAP.md) Phase 2 for detailed migration steps.
