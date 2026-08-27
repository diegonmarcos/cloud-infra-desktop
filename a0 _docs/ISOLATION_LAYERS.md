# Isolation Layers Specification

> **Goal**: Android/ChromeOS-style security with multiple isolation boundaries
> **Model**: Defense in depth - every layer adds protection

---

## Security Zones Overview

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              SECURITY ZONES                                   │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ZONE 0         ZONE 1a        ZONE 1b        ZONE 2         ZONE 3        │
│   RECOVERY       WEBCAM         SECURITY       SYSTEM         UNTRUSTED     │
│                                                                              │
│  ┌────────┐    ┌────────┐    ┌────────┐    ┌────────┐    ┌────────────┐    │
│  │        │    │        │    │        │    │        │    │████████████│    │
│  │ ALPINE │    │WINDOWS │    │  KALI  │    │ NIXOS  │    │█ MICROVM █│    │
│  │ LINUX  │    │  11    │    │ LINUX  │    │  HOST  │    │████████████│    │
│  │        │    │        │    │        │    │        │    │████████████│    │
│  └────────┘    └────────┘    └────────┘    └────────┘    └────────────┘    │
│                                                                              │
│  ENCRYPT:      ENCRYPT:      ENCRYPT:      ENCRYPT:      ENCRYPT:           │
│  None          None          None          LUKS          LUKS               │
│                                                                              │
│  ACCESS:       ACCESS:       ACCESS:       ACCESS:       ACCESS:             │
│  Always        Always        Always        Boot unlock   Boot unlock         │
│                                                                              │
│  PURPOSE:      PURPOSE:      PURPOSE:      PURPOSE:      PURPOSE:            │
│  Emergency     Webcam        Pentesting    Primary OS    Untrusted           │
│  repair        driver        security      + apps        workloads           │
│                                                                              │
│  TRUST:        TRUST:        TRUST:        TRUST:        TRUST:              │
│  100% (you)    50% (MS)      90% (tools)   100% (Nix)    0% (isolated)       │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Zone Details

### Zone 0: Recovery (Alpine Linux)

| Property | Value |
|----------|-------|
| **Location** | nvme0n1p3 (5GB ext4, unencrypted) |
| **Access** | Always bootable, no password needed |
| **Purpose** | Emergency repair when NixOS fails |
| **Tools** | cryptsetup, btrfs-progs, fsck, ssh |

**When to use:**
- NixOS won't boot
- LUKS needs repair
- Filesystem recovery needed
- Network debugging

**Capabilities:**
```bash
# Unlock LUKS
cryptsetup open /dev/nvme0n1p5 pool

# Mount BTRFS
mount /dev/mapper/pool /mnt

# Repair subvolumes
btrfs check --repair /dev/mapper/pool

# Network access for help
ssh user@recovery-station
```

### Zone 1a: Webcam (Windows 11 Lite)

| Property | Value |
|----------|-------|
| **Location** | nvme0n1p5 (~20GB NTFS, unencrypted) |
| **Access** | Always bootable |
| **Purpose** | Surface Pro webcam driver compatibility |
| **Why** | Linux lacks full Windows Hello camera support |

**Configuration:**
- Minimal Windows 11 install (debloated)
- Only webcam drivers installed
- Network streaming for webcam to NixOS
- Disabled: Windows Update, Defender, telemetry

**Webcam piping:**
```
Windows 11 (webcam) → OBS Virtual Camera → Network Stream
                                              ↓
NixOS (v4l2loopback) ← RTSP/NDI/MJPEG ←──────┘
```

### Zone 1b: Security (Kali Linux)

| Property | Value |
|----------|-------|
| **Location** | nvme0n1p4 (~20GB ext4, unencrypted) |
| **Access** | Always bootable |
| **Purpose** | Penetration testing and security auditing |
| **Why** | Dedicated security tooling isolated from main OS |

**Configuration:**
- Full Kali Linux install with Surface drivers
- All standard Kali security tools available
- Isolated from encrypted NixOS partition
- No access to LUKS data by design

**Key tools:**
```
Information Gathering: nmap, masscan, recon-ng
Web Testing: burpsuite, zap, sqlmap
Exploitation: metasploit, searchsploit
Password: john, hashcat, hydra
Wireless: aircrack-ng, wifite
```

**Isolation benefits:**
- Clean environment for security assessments
- No risk of compromising personal data
- Can forensically analyze systems without mounting encrypted partition
- Professional pentesting toolkit always available

### Zone 2: System (NixOS)

| Property | Value |
|----------|-------|
| **Location** | LUKS partition (@system/, @user/, @shared/) |
| **Access** | Boot unlock (USB key or password) |
| **Purpose** | Primary operating system |
| **Trust** | 100% - declarative, reproducible |

**Sub-zones within NixOS:**

| Sub-zone | Trust | Isolation | Examples |
|----------|-------|-----------|----------|
| Nix Native | 100% | None (host) | git, vim, htop |
| Distrobox | 80% | Namespace | dev environments |
| Flatpak | 60% | Bubblewrap | browsers, chat |
| Podman | 40% | Namespace | services |
| User Vault | 100% | LUKS-in-LUKS | secrets |

### Zone 3: Untrusted (microvm.nix)

| Property | Value |
|----------|-------|
| **Location** | @shared/microvm subvolume |
| **Access** | Boot unlock + on-demand VM |
| **Purpose** | Run untrusted code safely |
| **Trust** | 0% - assumes hostile code |
| **Integration** | NixOS-native, declarative VM definitions |

**Use cases:**
- CI/CD pipelines from untrusted repos
- Testing malware samples
- Running proprietary binaries
- Sandboxed development
- Isolated build environments

**Isolation properties:**
- Separate kernel (guest NixOS)
- Isolated memory
- No host filesystem access
- Network can be airgapped
- Hypervisor options: Firecracker, Cloud Hypervisor, QEMU

---

## Sandbox Types Comparison

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           SANDBOX TRUST LEVELS                               │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  TRUST   100%         80%          60%          40%           0%            │
│    │      │            │            │            │             │             │
│    ▼      ▼            ▼            ▼            ▼             ▼             │
│                                                                              │
│  ┌────────┐    ┌────────┐    ┌────────┐    ┌────────┐    ┌──────────┐      │
│  │  NIX   │    │DISTRO- │    │FLATPAK │    │ PODMAN │    │ MICROVM  │      │
│  │ NATIVE │    │  BOX   │    │        │    │        │    │          │      │
│  │        │    │        │    │        │    │        │    │ ┌──────┐ │      │
│  │  git   │    │  Arch  │    │Firefox │    │ nginx  │    │ │Guest │ │      │
│  │  vim   │    │  Fedora│    │ Slack  │    │Postgres│    │ │NixOS │ │      │
│  │  htop  │    │  Ubuntu│    │ VSCode │    │ Redis  │    │ └──────┘ │      │
│  │        │    │        │    │        │    │        │    │          │      │
│  └────────┘    └────────┘    └────────┘    └────────┘    └──────────┘      │
│                                                                              │
│  KERNEL     KERNEL      KERNEL      KERNEL      KERNEL                      │
│  Shared     Shared      Shared      Shared      ISOLATED                    │
│                                                                              │
│  OVERHEAD   OVERHEAD    OVERHEAD    OVERHEAD    OVERHEAD                    │
│  0%         ~1%         ~2%         ~2%         ~5-10%                      │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Detailed Sandbox Specifications

### 1. Nix Native (100% Trust)

```
┌─────────────────────────────────────────┐
│            NIX NATIVE                    │
├─────────────────────────────────────────┤
│                                         │
│  ISOLATION:     None                    │
│  FILESYSTEM:    Full access             │
│  NETWORK:       Full access             │
│  HARDWARE:      Full access             │
│  PERSISTENCE:   /nix/store (read-only)  │
│                                         │
│  USE FOR:                               │
│  • CLI tools (git, vim, ripgrep)        │
│  • System utilities (htop, btop)        │
│  • Development tools (gcc, cargo)       │
│  • Trusted applications                 │
│                                         │
│  ADVANTAGES:                            │
│  • Zero overhead                        │
│  • Full system integration              │
│  • Declarative via configuration.nix   │
│  • Atomic updates and rollback          │
│                                         │
└─────────────────────────────────────────┘
```

### 2. Distrobox (80% Trust)

```
┌─────────────────────────────────────────┐
│            DISTROBOX                     │
├─────────────────────────────────────────┤
│                                         │
│  ISOLATION:     Linux namespaces        │
│  FILESYSTEM:    $HOME shared            │
│  NETWORK:       Full (host network)     │
│  HARDWARE:      Selective passthrough   │
│  PERSISTENCE:   Container home in $HOME │
│                                         │
│  USE FOR:                               │
│  • Development environments             │
│  • Distro-specific tools (apt, dnf)     │
│  • GUI apps needing distro libs         │
│  • Testing across distributions         │
│                                         │
│  ADVANTAGES:                            │
│  • Feels like native environment        │
│  • Access to host files                 │
│  • Multiple distros simultaneously      │
│  • Lightweight (~1% overhead)           │
│                                         │
│  CONTAINERS:                            │
│  • arch-dev (Arch Linux, compilers)     │
│  • fedora-dev (Fedora, dnf tools)       │
│  • ubuntu-lts (Ubuntu, apt ecosystem)   │
│                                         │
└─────────────────────────────────────────┘
```

**Configuration:**
```bash
# Create development container
distrobox create --name arch-dev --image archlinux:latest

# Enter container
distrobox enter arch-dev

# Export app to host menu
distrobox-export --app code
```

### 3. Flatpak (60% Trust)

```
┌─────────────────────────────────────────┐
│            FLATPAK                       │
├─────────────────────────────────────────┤
│                                         │
│  ISOLATION:     Bubblewrap sandbox      │
│  FILESYSTEM:    XDG portals only        │
│  NETWORK:       Restricted by app       │
│  HARDWARE:      Portal-gated            │
│  PERSISTENCE:   ~/.var/app/<app-id>/    │
│                                         │
│  USE FOR:                               │
│  • Web browsers (Firefox, Chromium)     │
│  • Communication (Discord, Slack)       │
│  • Media apps (Spotify, VLC)            │
│  • Proprietary software                 │
│                                         │
│  ADVANTAGES:                            │
│  • Strong filesystem isolation          │
│  • Permission-based access              │
│  • App updates independent of OS        │
│  • Consistent runtime across distros    │
│                                         │
│  PERMISSIONS (per-app):                 │
│  • filesystem=home:ro (read-only home)  │
│  • socket=wayland (Wayland access)      │
│  • device=dri (GPU access)              │
│  • socket=pulseaudio (audio)            │
│                                         │
└─────────────────────────────────────────┘
```

**Permission management:**
```bash
# View app permissions
flatpak info --show-permissions org.mozilla.firefox

# Override permissions
flatpak override --user --nofilesystem=home org.example.App

# Use Flatseal GUI for permission management
flatpak install flathub com.github.tchx84.Flatseal
```

### 4. Podman (40% Trust)

```
┌─────────────────────────────────────────┐
│            PODMAN                        │
├─────────────────────────────────────────┤
│                                         │
│  ISOLATION:     Namespaces + cgroups    │
│  FILESYSTEM:    Volume mounts only      │
│  NETWORK:       Isolated (bridge/none)  │
│  HARDWARE:      Explicit passthrough    │
│  PERSISTENCE:   Named volumes           │
│                                         │
│  USE FOR:                               │
│  • Web services (nginx, caddy)          │
│  • Databases (postgres, redis)          │
│  • Development servers                  │
│  • Self-hosted apps                     │
│                                         │
│  ADVANTAGES:                            │
│  • Rootless by default                  │
│  • OCI-compatible images                │
│  • Compose file support                 │
│  • systemd integration                  │
│                                         │
│  NETWORK MODES:                         │
│  • bridge: isolated with port mapping   │
│  • host: shares host network            │
│  • none: no network access              │
│                                         │
└─────────────────────────────────────────┘
```

**Usage:**
```bash
# Run rootless container
podman run -d --name postgres \
  -v pgdata:/var/lib/postgresql/data \
  -p 5432:5432 \
  postgres:16

# Generate systemd unit
podman generate systemd --name postgres > ~/.config/systemd/user/postgres.service
```

### 5. microvm.nix (0% Trust)

```
┌─────────────────────────────────────────┐
│            MICROVM.NIX                   │
├─────────────────────────────────────────┤
│                                         │
│  ISOLATION:     Hardware VM (KVM)       │
│  FILESYSTEM:    Completely isolated     │
│  NETWORK:       Isolated (can airgap)   │
│  HARDWARE:      Virtualized             │
│  PERSISTENCE:   Ephemeral by default    │
│  INTEGRATION:   NixOS-native            │
│                                         │
│  USE FOR:                               │
│  • Untrusted code execution             │
│  • CI/CD from unknown repos             │
│  • Malware analysis                     │
│  • Security testing                     │
│  • Isolated build environments          │
│                                         │
│  ADVANTAGES:                            │
│  • Kernel-level isolation               │
│  • Even kernel exploits contained       │
│  • Declarative VM definitions           │
│  • ~5-10% overhead (acceptable)         │
│  • Multiple hypervisor backends         │
│  • Full NixOS in guest VM               │
│                                         │
│  HYPERVISORS:                           │
│  • Firecracker (default, fastest)       │
│  • Cloud Hypervisor                     │
│  • QEMU (most compatible)               │
│  • kvmtool                              │
│                                         │
│  REQUIREMENTS:                          │
│  • Intel VT-x or AMD-V enabled          │
│  • KVM module loaded                    │
│  • microvm.nix flake input              │
│                                         │
└─────────────────────────────────────────┘
```

**Configuration:**
```nix
# flake.nix - add microvm.nix input
{
  inputs.microvm = {
    url = "github:astro/microvm.nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}

# configuration.nix
microvm.host.enable = true;

microvm.vms.sandbox = {
  config = {
    microvm = {
      hypervisor = "firecracker";
      vcpu = 2;
      mem = 2048;
    };
    # Guest NixOS config
    networking.hostName = "sandbox";
  };
};
```

**Usage:**
```bash
# Start microVM
systemctl start microvm@sandbox

# Connect to VM
microvm -c sandbox

# Stop VM
systemctl stop microvm@sandbox
```

---

## Encryption Layers

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           ENCRYPTION HIERARCHY                               │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  LAYER 0: UNENCRYPTED                                                       │
│  ═══════════════════════════════════════════════════════════════════════    │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  • EFI partition (required by UEFI)                                  │   │
│  │  • /boot partition (kernel, initrd)                                  │   │
│  │  • Alpine recovery OS                                                │   │
│  │  • Windows 11 (webcam)                                               │   │
│  │                                                                      │   │
│  │  THREAT: Physical attacker can read/modify boot files               │   │
│  │  MITIGATION: Secure Boot (future), integrity checking               │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  LAYER 1: LUKS ENCRYPTED (System)                                           │
│  ═══════════════════════════════════════════════════════════════════════    │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  • NixOS system files (@system/)                                     │   │
│  │  • User home directory (@user/home)                                  │   │
│  │  • Container storage (@shared/)                                      │   │
│  │                                                                      │   │
│  │  UNLOCK: USB keyfile (automatic) OR password                        │   │
│  │  THREAT: Lost/stolen laptop → data unreadable                       │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  LAYER 2: LUKS-IN-LUKS (Vault)                                              │
│  ═══════════════════════════════════════════════════════════════════════    │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  • SSH private keys                                                  │   │
│  │  • API tokens                                                        │   │
│  │  • GPG keys                                                          │   │
│  │  • Password database                                                 │   │
│  │  • 2FA recovery codes                                                │   │
│  │  • Identity documents                                                │   │
│  │                                                                      │   │
│  │  UNLOCK: Separate key (manual, on-demand)                           │   │
│  │  THREAT: System compromise → vault still locked                     │   │
│  │  TOOL: Tomb (LUKS file container)                                   │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Mutability Layers

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           MUTABILITY MODEL                                   │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  IMMUTABLE (Read-Only)                  MUTABLE (Read-Write)                │
│  ═════════════════════                  ════════════════════                │
│                                                                              │
│  ┌─────────────────────┐               ┌─────────────────────┐              │
│  │                     │               │                     │              │
│  │  /nix/store         │               │  /var/lib           │              │
│  │  (derivations)      │               │  (system state)     │              │
│  │                     │               │                     │              │
│  │  /                  │               │  /var/log           │              │
│  │  (tmpfs root)       │               │  (logs)             │              │
│  │                     │               │                     │              │
│  │  /etc               │               │  /home              │              │
│  │  (generated)        │               │  (user data)        │              │
│  │                     │               │                     │              │
│  └─────────────────────┘               │  @shared/*          │              │
│                                        │  (containers)       │              │
│  CHANGES: Only via                     │                     │              │
│  nixos-rebuild switch                  └─────────────────────┘              │
│                                                                              │
│  WIPE ON BOOT: Yes                     PERSIST: Yes                         │
│  (/ is tmpfs)                          (BTRFS subvolumes)                   │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Decision Matrix

| Scenario | Sandbox | Reason |
|----------|---------|--------|
| Editing code | Nix Native | Full access needed |
| Compiling Rust project | Distrobox | Arch has latest toolchains |
| Web browsing | Flatpak | Isolate from filesystem |
| Slack/Discord | Flatpak | Proprietary, limited trust |
| Running PostgreSQL | Podman | Service isolation |
| CI/CD from GitHub | microvm.nix | Unknown code |
| Testing malware | microvm.nix | Zero trust |
| Security testing | microvm.nix | Kernel-level isolation |
| SSH keys | Vault (Tomb) | Maximum protection |
| API tokens | Vault (Tomb) | Maximum protection |

---

## NixOS Configuration

```nix
# configuration.nix additions for isolation layers

{ config, pkgs, ... }:

{
  # microvm.nix (add to flake.nix inputs first)
  # inputs.microvm.url = "github:astro/microvm.nix";
  microvm.host.enable = true;

  # Define security sandbox VM
  microvm.vms.sandbox = {
    config = {
      microvm = {
        hypervisor = "firecracker";
        vcpu = 2;
        mem = 2048;
        interfaces = [{
          type = "user";
          id = "vm-sandbox";
          mac = "02:00:00:00:00:01";
        }];
      };
      networking.hostName = "sandbox";
    };
  };

  # Distrobox
  environment.systemPackages = with pkgs; [
    distrobox
  ];

  # Flatpak
  services.flatpak.enable = true;
  xdg.portal.enable = true;

  # Podman (rootless)
  virtualisation.podman = {
    enable = true;
    dockerCompat = false;
    defaultNetwork.settings.dns_enabled = true;
  };

  # Tomb for vault
  environment.systemPackages = with pkgs; [
    tomb
    pinentry-curses  # For GPG passphrase entry
  ];
}
```
