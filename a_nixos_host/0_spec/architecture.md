# NixOS Host Architecture

> **Device**: Surface Pro 8 (Intel Tiger Lake, 8GB RAM, 256GB NVMe)
> **OS**: NixOS 24.11 with Full Impermanence
> **Boot**: rEFInd / GRUB (LUKS2 unlock)
> **Status**: Primary OS (standalone, not dual-boot)

---

## Overview

NixOS serves as the primary operating system with full impermanence (tmpfs root). All state is explicitly declared in Nix expressions and persisted via the impermanence module.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           SURFACE PRO 8 NixOS Host                           │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                              RUNTIME                                   │  │
│  │                                                                        │  │
│  │   /                  tmpfs (2GB RAM) - wiped every boot               │  │
│  │   /nix               @system/nix subvolume (read-only store)          │  │
│  │   /var/lib           @system/state subvolume (system state)           │  │
│  │   /var/log           @system/logs subvolume (logs)                    │  │
│  │   /home              @user/home subvolume (user data)                 │  │
│  │   /var/lib/containers  @shared/containers subvolume (Podman)          │  │
│  │   /var/lib/flatpak     @shared/flatpak subvolume (Flatpak)            │  │
│  │   /var/lib/microvms    @shared/microvm subvolume (microvm.nix)        │  │
│  │   /var/lib/waydroid    @shared/waydroid subvolume (Android)           │  │
│  │                                                                        │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                              STORAGE                                   │  │
│  │                                                                        │  │
│  │   nvme0n1p1 (100MB)  EFI System Partition (/boot/efi)                 │  │
│  │   nvme0n1p2 (2GB)    /boot partition (kernels, initrd)                │  │
│  │   nvme0n1p3 (5GB)    Alpine Recovery OS (unencrypted)                 │  │
│  │   nvme0n1p4 (~20GB)  Kali Linux Security (unencrypted)                │  │
│  │   nvme0n1p5 (~20GB)  Windows 11 Webcam (unencrypted)                  │  │
│  │   nvme0n1p6 (~180GB) LUKS2 → BTRFS Pool (encrypted)                   │  │
│  │                                                                        │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Design Principles

| Principle | Implementation |
|-----------|----------------|
| **Declarative** | All config in Nix expressions, reproducible |
| **Immutable Core** | tmpfs root, /nix/store read-only |
| **Explicit Persistence** | Only declared paths survive reboot |
| **Semantic Storage** | @system/, @user/, @shared/ subvolumes |
| **Defense in Depth** | LUKS + namespaces + microvm.nix |

---

## Filesystem Layout

### Mount Points

| Mount Point | Source | Type | Purpose |
|-------------|--------|------|---------|
| `/` | none | tmpfs | Ephemeral root (2GB RAM) |
| `/nix` | @system/nix | btrfs | Nix store (immutable packages) |
| `/var/lib` | @system/state | btrfs | System persistent state |
| `/var/log` | @system/logs | btrfs | System logs |
| `/home` | @user/home | btrfs | User data and configs |
| `/var/lib/containers` | @shared/containers | btrfs | Podman/Docker storage |
| `/var/lib/flatpak` | @shared/flatpak | btrfs | Flatpak apps |
| `/var/lib/microvms` | @shared/microvm | btrfs | microvm.nix VMs |
| `/var/lib/waydroid` | @shared/waydroid | btrfs | Android container |
| `/boot` | nvme0n1p2 | ext4 | Kernels, initramfs |
| `/boot/efi` | nvme0n1p1 | vfat | EFI System Partition |

### BTRFS Subvolume Structure

```
/dev/mapper/pool (BTRFS, zstd compression)
│
├── @system/                    # OS-managed, declarative
│   ├── nix/                    # Nix store (~30-50GB)
│   ├── state/                  # /var/lib state (~5GB)
│   └── logs/                   # /var/log (~2-5GB)
│
├── @user/                      # Personal data
│   └── home/                   # /home/user (~20-50GB)
│
└── @shared/                    # Shared resources
    ├── containers/             # Podman storage (~30GB)
    ├── flatpak/                # Flatpak apps (~20GB)
    ├── microvm/                # microvm.nix VMs (~20GB)
    └── waydroid/               # Android (~10GB)
```

---

## Impermanence Configuration

### What Survives Reboot

```nix
# System state (bound from @system/state)
environment.persistence."/persist" = {
  directories = [
    "/var/lib/nixos"           # NixOS state
    "/var/lib/systemd"         # systemd machine state
    "/var/lib/bluetooth"       # Bluetooth pairings
    "/var/lib/NetworkManager"  # Network connections
  ];
  files = [
    "/etc/machine-id"
    "/etc/ssh/ssh_host_ed25519_key"
    "/etc/ssh/ssh_host_ed25519_key.pub"
    "/etc/ssh/ssh_host_rsa_key"
    "/etc/ssh/ssh_host_rsa_key.pub"
  ];
};

# User state (bound from @user/home)
environment.persistence."/persist".users.user = {
  directories = [
    ".config"                  # App configurations
    ".local"                   # Local data, scripts
    ".cache"                   # Caches
    ".ssh"                     # SSH keys
    ".gnupg"                   # GPG keys
    ".var"                     # Flatpak user data
    "Documents"
    "Downloads"
    "Projects"
  ];
  files = [
    ".bash_history"
    ".zsh_history"
    ".local/share/fish/fish_history"
    "vault.tomb"               # Encrypted secrets
  ];
};
```

### What Gets Wiped

Everything in `/` that's not explicitly persisted:
- `/tmp`, `/var/tmp` (tmpfs anyway)
- `/root` (root home)
- `/etc` (regenerated from Nix)
- Application runtime state

---

## Container Runtime Comparison

| Runtime | Kernel | Filesystem | Network | Overhead | Use Case |
|---------|--------|------------|---------|----------|----------|
| **Nix Native** | Shared | Full | Full | 0% | CLI tools |
| **Distrobox** | Shared | $HOME | Full | ~1% | Dev environments |
| **Flatpak** | Shared | Portal | Restricted | ~2% | GUI apps |
| **Podman** | Shared | Volume | Isolated | ~2% | Services |
| **microvm.nix** | **Isolated** | **Isolated** | Isolated | ~5-10% | Untrusted |

### When to Use Each

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           CONTAINER DECISION TREE                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Is it a CLI tool or system utility?                                    │
│    YES → Nix Native (add to configuration.nix)                          │
│                                                                         │
│  Is it a development environment (compiler, interpreter)?               │
│    YES → Distrobox (create Arch/Fedora/Ubuntu container)                │
│                                                                         │
│  Is it a GUI application (browser, chat, office)?                       │
│    YES → Flatpak (install from Flathub)                                 │
│                                                                         │
│  Is it a long-running service (database, web server)?                   │
│    YES → Podman (rootless container)                                    │
│                                                                         │
│  Is it untrusted code or CI/CD workload?                                │
│    YES → microvm.nix (VM isolation)                                     │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Desktop Sessions (SDDM)

| Session | Type | Protocol | Use Case |
|---------|------|----------|----------|
| **KDE Plasma** | Desktop | Wayland | Full desktop, Windows-like (default) |
| **GNOME** | Desktop | Wayland | ChromeOS-like, touch-friendly |
| **Waydroid (Android)** | Container | Wayland | Android apps fullscreen |
| **Openbox (Light)** | WM | X11 | Minimal, fast, low RAM |
| **Brave Kiosk** | Browser | Wayland | Web-only, digital signage |

### Session Configuration

```nix
# Custom sessions in configuration.nix

let
  # Waydroid session (Android in fullscreen)
  waydroid-session = pkgs.writeTextDir "share/wayland-sessions/waydroid.desktop" ''
    [Desktop Entry]
    Name=Waydroid (Android)
    Comment=Android in a container
    Exec=${pkgs.cage}/bin/cage -s -- ${pkgs.waydroid}/bin/waydroid show-full-ui
    Type=Application
    DesktopNames=Waydroid
  '';

  # Brave Kiosk session
  brave-kiosk = pkgs.writeTextDir "share/wayland-sessions/brave-kiosk.desktop" ''
    [Desktop Entry]
    Name=Brave Kiosk
    Comment=Brave Browser in Kiosk Mode
    Exec=${pkgs.cage}/bin/cage -s -- ${pkgs.brave}/bin/brave --kiosk --no-first-run
    Type=Application
    DesktopNames=BraveKiosk
  '';
in {
  services.displayManager = {
    sddm = {
      enable = true;
      wayland.enable = true;
    };
    sessionPackages = [ waydroid-session brave-kiosk ];
  };

  # KDE Plasma 6
  services.desktopManager.plasma6.enable = true;

  # GNOME
  services.xserver.desktopManager.gnome.enable = true;

  # Openbox
  services.xserver.windowManager.openbox.enable = true;

  # Waydroid
  virtualisation.waydroid.enable = true;
}
```

---

## Security Stack

| Layer | Implementation |
|-------|----------------|
| **Disk** | LUKS2 (USB keyfile + password) |
| **Vault** | Tomb (LUKS-in-LUKS for secrets) |
| **Network** | nftables firewall |
| **Apps** | Flatpak sandboxing |
| **Untrusted** | microvm.nix VMs |
| **Updates** | Atomic generations (rollback) |

---

## Build Pipeline

```bash
# Check configuration
nix flake check

# Build without switching
sudo nixos-rebuild build --flake .#surface

# Switch to new generation
sudo nixos-rebuild switch --flake .#surface

# Rollback if needed
sudo nixos-rebuild switch --rollback

# List generations
sudo nix-env --list-generations -p /nix/var/nix/profiles/system
```

---

## Key UUIDs

| Component | UUID |
|-----------|------|
| EFI Partition | `2CE0-6722` |
| /boot Partition | `0eaf7961-48c5-4b55-8a8f-04cd0b71de07` |
| LUKS Partition | `3c75c6db-4d7c-4570-81f1-02d168781aac` |
| USB Keyfile | `223C-F3F8` (Ventoy) |

---

## Related Documentation

| Document | Path | Purpose |
|----------|------|---------|
| Main Architecture | `0_spec/ARCHITECTURE.md` | High-level overview |
| Disk Layout | `0_spec/DISK_LAYOUT.md` | Partition details |
| Isolation Layers | `0_spec/ISOLATION_LAYERS.md` | Security zones |
| Personal Space | `0_spec/PERSONAL_SPACE.md` | User organization |
| Roadmap | `0_spec/ROADMAP.md` | Implementation plan |
| Runbook | `a_nixos_host/0_spec/runbook.md` | Step-by-step procedures |
