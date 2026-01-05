# NixOS Bifrost Architecture

## Overview

NixOS companion to Kinoite Bifrost - a declarative, reproducible operating system for the Surface Pro dual-boot setup.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        SURFACE PRO 8                                │
├─────────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   rEFInd     │  │   Kinoite    │  │    NixOS     │              │
│  │  Bootloader  │──│   Bifrost    │──│   Bifrost    │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
│         │                 │                 │                       │
│         ▼                 ▼                 ▼                       │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    LUKS2 Encrypted Pool                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │  │
│  │  │   @root     │  │  @nixos     │  │  @shared    │          │  │
│  │  │  (Kinoite)  │  │  (NixOS)    │  │  (common)   │          │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘          │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## Comparison: Kinoite vs NixOS

| Feature | Kinoite Bifrost | NixOS Bifrost |
|---------|-----------------|---------------|
| **Base** | Fedora Atomic | NixOS |
| **Updates** | rpm-ostree | nix rebuild |
| **Config** | Containerfile | Nix expressions |
| **Rollback** | ostree | generations |
| **Packages** | Flatpak + containers | nixpkgs + overlays |
| **Desktop** | KDE + Openbox | KDE Plasma 6 |
| **Build Tool** | bootc-image-builder | nixos-generators |

## Directory Structure

```
/home/diego/mnt_git/unix/a_nixos_host/     # Git repo (scripts & config)
├── 0_spec/
│   ├── architecture.md                    # This file
│   └── runbook.md                         # Step-by-step procedures
├── 1_oci/
│   └── (containerfile variants)
├── flake.nix                              # Flake definition
├── configuration.nix                      # NixOS configuration
└── build.sh                               # Build orchestrator

/mnt/kinoite/@images/a_nixos_host/         # Build outputs (large files)
├── 0_podman/                              # Podman state (if needed)
├── 1_oci/                                 # OCI exports
├── 2_raw/                                 # Built images
│   ├── nixos.raw                          # Raw EFI disk image
│   ├── nixos.iso                          # Bootable ISO
│   └── nixos.qcow2                        # QCOW2 for VMs
└── 3_deploy/                              # Installation artifacts
```

## Build Pipeline

```
┌─────────────────────────────────────────────────────────────────┐
│                      BUILD PIPELINE                              │
└─────────────────────────────────────────────────────────────────┘

 1. Configuration          2. Evaluation           3. Build
┌───────────────┐      ┌───────────────┐      ┌───────────────┐
│ flake.nix     │      │ nix flake     │      │ nixos-        │
│ configuration │ ───▶ │ check         │ ───▶ │ generators    │
│ .nix          │      │               │      │               │
└───────────────┘      └───────────────┘      └───────────────┘
                                                      │
                              ┌────────────────────────┤
                              │                        │
                              ▼                        ▼
                       ┌───────────┐            ┌───────────┐
                       │ raw-efi   │            │   iso     │
                       │ (install) │            │  (usb)    │
                       └───────────┘            └───────────┘
                              │
                              ▼
 4. Deploy               5. Test
┌───────────────┐      ┌───────────────┐
│ burn to USB   │      │ VM (QCOW2)    │
│ or install    │ ───▶ │ virt-manager  │
│ to disk       │      │               │
└───────────────┘      └───────────────┘
```

## Output Formats

| Format | Use Case | Command |
|--------|----------|---------|
| `raw-efi` | Direct disk installation | `./build.sh build raw` |
| `iso` | USB boot for installation | `./build.sh build iso` |
| `qcow` | VM testing (libvirt) | `./build.sh build qcow` |
| `vm` | Quick test (nix run) | `./build.sh build vm` |

## Installation Layout

### BTRFS Subvolumes

```
/dev/mapper/cryptroot
├── @              # NixOS root (/)
├── @home          # User data (/home)
├── @nix           # Nix store (/nix)
└── @snapshots     # Backup snapshots
```

### EFI Partition

```
/boot/efi/
├── EFI/
│   ├── refind/
│   │   └── refind.conf
│   ├── systemd/
│   │   └── systemd-bootx64.efi
│   └── nixos/
│       └── kernel + initrd
└── loader/
    └── entries/
```

## Package Sources

1. **nixpkgs** - Primary package source (100k+ packages)
2. **Overlays** - Custom package modifications
3. **Flake inputs** - External flakes (home-manager, etc.)
4. **Flatpak** - GUI apps not in nixpkgs
5. **Containers** - Dev environments (devenv, devbox)

## Security Stack

| Layer | Implementation |
|-------|----------------|
| Disk | LUKS2 + Argon2id |
| Boot | Secure Boot (optional) |
| Firewall | nftables via nixos |
| Updates | Atomic (generations) |
| Audit | Built-in logging |

## Differences from Kinoite

### What NixOS Does Better
- **Reproducibility**: Exact same system from config
- **Rollback**: Boot into any previous generation
- **Dev environments**: nix-shell, devenv, direnv
- **Configuration**: Everything in one place (flake)

### What Kinoite Does Better
- **Containers**: Better Podman/Docker integration
- **Waydroid**: Android apps support
- **Flatpak**: First-class citizen
- **Corporate**: SELinux, RHEL compatibility

## Related Resources

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [nixos-generators](https://github.com/nix-community/nixos-generators)
- [Kinoite Bifrost](../a_kinoite_host/README.md)
