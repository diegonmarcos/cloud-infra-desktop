# NixOS Surface Pro 8 Configuration

Flake-based NixOS configuration for Surface Pro 8 with ephemeral root (tmpfs) and persistent homes (btrfs).

## Quick Links

| Document | Audience | Description |
|----------|----------|-------------|
| [USER-MANUAL.md](0_spec/USER-MANUAL.md) | **Users** | Daily usage, commands, troubleshooting |
| [ARCHITECTURE.md](0_spec/ARCHITECTURE.md) | **Engineers** | Technical design, subvolumes, boot flow |
| [ISSUES-STATUS.md](ISSUES-STATUS.md) | **Developers** | Known issues and fix status |

## Repository Structure

```
a_nixos_host/
├── README.md                    # This file (index)
├── flake.nix                    # Flake definition
├── flake.lock                   # Locked dependencies
├── configuration.nix            # Main NixOS configuration
├── hardware-configuration.nix   # Hardware-specific settings
│
├── 0_spec/                      # Documentation
│   ├── USER-MANUAL.md           # User guide (quick reference)
│   ├── ARCHITECTURE.md          # Technical documentation
│   ├── runbook.md               # Operational procedures
│   └── task_1.md                # Task notes
│
├── build.sh                     # Build script (iso, raw, qcow)
├── diagnose-nixos.sh            # Diagnostic script
├── ISSUES-STATUS.md             # Issue tracker
├── CHANGES-2026-01-08.md        # Change log
└── logs/                        # Build logs
```

## System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    EPHEMERAL ROOT (tmpfs)                   │
│  /etc, /var, /tmp - regenerated every boot from config      │
└─────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│   @nixos/nix  │    │  @home-diego  │    │   @shared     │
│  /nix (store) │    │  /home/diego  │    │  /mnt/shared  │
│   Persistent  │    │   Portable    │    │   Cross-OS    │
└───────────────┘    └───────────────┘    └───────────────┘
```

## Quick Commands

```bash
# Rebuild system
sudo nixos-rebuild switch --flake /nix/specs#surface

# Or from git repo
sudo nixos-rebuild switch --flake .#surface

# Rollback
sudo nixos-rebuild switch --rollback

# Build ISO (from Kubuntu)
./build.sh build iso
```

## Access Points

| Path | Description |
|------|-------------|
| `/nix/specs/` | Symlink to this repo (after boot) |
| `/mnt/kubuntu/.../a_nixos_host/` | Git repo location |

## Credentials

- **User:** diego / guest
- **Password:** 1234567890

---

*NixOS 24.11 | linux-surface kernel | Surface Pro 8*
