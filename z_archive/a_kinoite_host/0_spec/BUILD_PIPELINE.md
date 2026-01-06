# Kinoite Bifrost Build Pipeline

## Overview

The build pipeline converts configuration into a bootable OS image through 3 stages:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    KINOITE BIFROST BUILD PIPELINE                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  STAGE 1: OCI                STAGE 2: RAW              STAGE 3:    │
│  (Container Image)           (Disk Image)              DEPLOY      │
│                                                                     │
│  ┌───────────────┐          ┌─────────────┐         ┌───────────┐  │
│  │ Containerfile │──podman──│   bootc-    │──copy──▶│    VM     │  │
│  │   .surface    │   build  │   image-    │         │   USB     │  │
│  │  + scripts/   │          │   builder   │         │  Install  │  │
│  └───────────────┘          └─────────────┘         └───────────┘  │
│         │                          │                               │
│         ▼                          ▼                               │
│  localhost/kinoite-          disk.raw                              │
│  surface:41                  (~15-20GB)                            │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
a_kinoite_host/                    # Git repository
├── 0_spec/                        # Documentation
│   ├── ARCHITECTURE.md            # Master specification
│   └── BUILD_PIPELINE.md          # This file
├── 1_oci/                         # Stage 1: OCI container
│   ├── Containerfile.surface      # Main image definition
│   ├── Containerfile              # Base image (minimal)
│   ├── Containerfile.profile      # User profile additions
│   └── scripts/                   # Files copied into image
│       ├── configure-sessions.sh
│       ├── configure-sessions.service
│       └── session-switcher.sh
├── 2_raw/                         # Stage 2: Output (gitignored)
│   └── .gitkeep
├── 3_deploy/                      # Stage 3: Deployment targets
│   ├── vm/.gitkeep
│   ├── usb/.gitkeep
│   ├── install/.gitkeep
│   └── iso/.gitkeep
└── build.sh                       # Master orchestrator

/shared/@images/a_kinoite_host/    # Build artifacts (not in git)
├── 1_oci/                         # Cached OCI tar
│   └── fedora-kinoite-41.tar
├── 2_raw/                         # Raw disk images
│   ├── btrfs/
│   │   ├── disk.raw              # BTRFS image (~19GB)
│   │   └── manifest-raw.json
│   └── ext4/
│       ├── disk.raw              # EXT4 image (~15GB)
│       └── manifest-raw.json
└── 3_deploy/                      # Deployment targets
    ├── usb/
    │   └── kinoite-kde-auth.raw
    ├── iso/
    │   └── Fedora-Kinoite-*.iso
    └── qcow2/
        └── kinoite-host.qcow2
```

## Stage 1: OCI Container

**Input:** Containerfile.surface + scripts/
**Output:** Container image `localhost/kinoite-surface:41`
**Tool:** `podman build`

The Containerfile defines the complete OS:

```dockerfile
FROM quay.io/fedora/fedora-kinoite:41

# Install packages via rpm-ostree
RUN rpm-ostree install package1 package2

# Copy scripts (paths relative to build context)
COPY 1_oci/scripts/configure-sessions.sh /usr/local/bin/

# Configure services
RUN systemctl enable sshd
```

**Key Points:**
- Base image is Fedora Kinoite 41 (immutable OS)
- Packages installed with `rpm-ostree install`
- COPY paths are relative to where `podman build` is run (project root)
- Service files need `chmod 644` after COPY

## Stage 2: RAW Disk Image

**Input:** Container image
**Output:** `disk.raw` bootable disk image
**Tool:** `bootc-image-builder`

```bash
podman run --privileged \
    -v /output:/output \
    quay.io/centos-bootc/bootc-image-builder:latest \
    build --type raw --rootfs btrfs \
    localhost/kinoite-surface:41
```

**Key Points:**
- Runs as privileged container (needs loop devices)
- Output goes to `/output/image/disk.raw`
- Supports `--rootfs ext4` or `--rootfs btrfs`
- Takes ~10-15 minutes
- Resulting image is ~15-20GB

**What bootc-image-builder does:**
1. Creates partition table (EFI + root)
2. Formats filesystems
3. Extracts container layers to root
4. Installs bootloader (GRUB/systemd-boot)
5. Configures kernel + initramfs

## Stage 3: Deployment

### VM Testing

```bash
./build.sh vm btrfs [vm_name]
```

Uses `virt-install` to create libvirt VM:
- 4GB RAM, 2 vCPUs
- virgl 3D acceleration (software OpenGL)
- UEFI boot
- NAT networking

### USB Boot

```bash
./build.sh burn btrfs /dev/sdX
```

Writes raw image directly to USB drive with `dd`.

### Full Installation

```bash
./build.sh install
```

Multi-phase installation:
1. **Partition** - GPT layout (EFI, LUKS, Windows)
2. **LUKS** - Dual-password encryption + BTRFS subvolumes
3. **Deploy** - Extract image to @root
4. **Initramfs** - Configure profile detection

## Build Commands

```bash
# Full TUI menu
sudo ./build.sh

# CLI commands
sudo ./build.sh surface          # Build Surface image
sudo ./build.sh build btrfs      # Build basic btrfs image
sudo ./build.sh vm btrfs         # Create VM from btrfs image
sudo ./build.sh burn btrfs /dev/sdX  # Burn to USB
sudo ./build.sh install          # Full installation

# Non-root tools
./build.sh mount <vm_name>       # Mount VM home via SSHFS
./build.sh unmount <path>        # Unmount
```

## Important Notes

### Containerfile COPY Paths
COPY paths in Containerfile are relative to the **build context** (where `podman build` runs), NOT the Containerfile location. Since build.sh runs from project root:
```dockerfile
# Correct (relative to project root)
COPY 1_oci/scripts/foo.sh /destination

# Wrong (would look for scripts/ in project root)
COPY scripts/foo.sh /destination
```

### bootc-image-builder Output
The tool always outputs to `/output/image/disk.raw`. The build.sh moves this to the expected location:
```
/output/image/disk.raw → $OUTPUT_BASE/2_raw/{btrfs,ext4}/disk.raw
```

### VM GPU Limitations
- Intel iGPU **cannot** be passed through to VMs
- Only discrete GPUs support VFIO passthrough
- Waydroid requires real GPU - will NOT work in VMs
- virgl provides software 3D for basic desktop use

### System Groups
bootc-image-builder strips `/etc/group` to minimal entries. The Containerfile must explicitly create required groups:
```dockerfile
RUN groupadd -g 29 audio && \
    groupadd -g 39 video && \
    # ... etc
```
