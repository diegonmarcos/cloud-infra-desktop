# Diego's Portable Dev Environment

> **Owner**: Diego Nepomuceno Marcos
> **Created**: 2026-01-08
> **System**: Nix Home Manager (Standalone)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         NIX FLAKE                                   │
│                    (Single Source of Truth)                         │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    8 PROFILE CATEGORIES                      │   │
│  │                                                              │   │
│  │  1. Shell & Core      5. Security & Network                 │   │
│  │  2. Dev Languages     6. Data Science                       │   │
│  │  3. Build & Debug     7. Productivity                       │   │
│  │  4. Containers/Cloud  8. Media & Graphics                   │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                      DOTFILES                                │   │
│  │  Fish, Bash, Starship, Vim, Git, Tmux, KDE                  │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                       PRESETS                                │   │
│  │  full | cli | minimal | server                              │   │
│  └─────────────────────────────────────────────────────────────┘   │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
         ┌───────────────────────┼───────────────────────┐
         │                       │                       │
         ▼                       ▼                       ▼
┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
│   PURE NIX      │   │   NIX IMAGE     │   │  CONTAINERFILE  │
│   (Native)      │   │   (nix build)   │   │   (Fallback)    │
│                 │   │                 │   │                 │
│ home-manager    │   │ dockerTools.    │   │ Traditional     │
│ switch          │   │ buildImage      │   │ OCI build       │
└────────┬────────┘   └────────┬────────┘   └────────┬────────┘
         │                     │                     │
         │                     └──────────┬──────────┘
         │                                │
         │                     ┌──────────┴──────────┐
         │                     │                     │
         │                     ▼                     ▼
         │          ┌─────────────────┐   ┌─────────────────┐
         │          │ PODMAN/DOCKER   │   │   DISTROBOX     │
         │          │ COMPOSE         │   │                 │
         │          │                 │   │ Host-integrated │
         │          │ Isolated env    │   │ container       │
         │          └─────────────────┘   └─────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      ANY LINUX SYSTEM                               │
│              (Kubuntu, Arch, Fedora, NixOS, etc.)                   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Directory Structure

```
b_user_diego_nix/
├── 0.spec/                      # Documentation
│   ├── spec.md                  # This file (architecture)
│   └── README.md                # Usage guide
│
├── 1.ops/                       # Scripts & operations
│   ├── install.sh               # Fresh Nix + Home Manager install
│   ├── switch.sh                # Rebuild configuration
│   ├── update.sh                # Update flake inputs
│   ├── container-build.sh       # Build Nix OCI image
│   ├── container-run.sh         # Run container
│   └── distrobox-create.sh      # Create distrobox
│
├── container/                   # Container definitions
│   ├── compose.yaml             # Podman/Docker Compose
│   ├── Containerfile            # Fallback OCI build
│   ├── distrobox.ini            # Distrobox configuration
│   └── .containerignore
│
├── modules/                     # Nix modules
│   ├── common.nix               # Shared config (shells, editors)
│   ├── profiles/                # 8 package categories
│   │   ├── 1-shell-core.nix
│   │   ├── 2-dev-languages.nix
│   │   ├── 3-build-debug.nix
│   │   ├── 4-containers-cloud.nix
│   │   ├── 5-security-network.nix
│   │   ├── 6-data-science.nix
│   │   ├── 7-productivity.nix
│   │   └── 8-media-graphics.nix
│   ├── programs/                # Dotfile configurations
│   │   ├── shells/
│   │   │   ├── bash.nix
│   │   │   ├── fish.nix
│   │   │   ├── zsh.nix
│   │   │   └── starship.nix
│   │   ├── editors/
│   │   │   └── vim.nix
│   │   ├── git.nix
│   │   └── tmux.nix
│   └── dotfiles/                # Extra config files
│       ├── fish/                # Fish extras (config.fish)
│       └── kde/                 # KDE configs
│
├── hosts/                       # Host-specific configs
│   ├── surface.nix              # Surface Pro 8
│   ├── desktop.nix              # Desktop workstation
│   └── server.nix               # Server/VPS
│
├── lib/                         # Helper functions
│
├── flake.nix                    # Main entry point
└── flake.lock                   # Locked dependencies
```

---

## 8 Profile Categories

| # | Profile | Packages | Description |
|---|---------|----------|-------------|
| 1 | **shell-core** | ~35 | CLI essentials: eza, bat, fd, fzf, ripgrep, zoxide |
| 2 | **dev-languages** | ~15 | Rust, Go, Node, Python, C/C++, Java |
| 3 | **build-debug** | ~20 | cmake, gdb, valgrind, shellcheck, direnv |
| 4 | **containers-cloud** | ~25 | podman, kubectl, terraform, aws/gcp/azure |
| 5 | **security-network** | ~25 | nmap, wireguard, gnupg, tor, openssl |
| 6 | **data-science** | ~30 | pandas, torch, jupyter, postgres, R |
| 7 | **productivity** | ~20 | obsidian, libreoffice, taskwarrior |
| 8 | **media-graphics** | ~25 | ffmpeg, gimp, obs, mpv, inkscape |

**Total: ~195 packages**

---

## Presets

| Preset | Profiles | Use Case |
|--------|----------|----------|
| **full** | 1-8 | Full development workstation |
| **cli** | 1-6 | CLI-only (no GUI apps) |
| **minimal** | 1-3 | Base development |
| **server** | 1, 4, 5 | Cloud/server operations |

---

## 5 Deployment Methods

### Method 1: Pure Nix (Native)
```bash
# Install Nix + apply config
./1.ops/install.sh surface

# Or manually:
home-manager switch --flake .#diego@surface
```

### Method 2: Nix-Built Container
```bash
# Build OCI image with Nix
nix build .#container

# Load into Podman
podman load < result

# Run
podman run -it diego-dev:latest
```

### Method 3: Podman Compose
```bash
cd container
podman-compose up -d
podman-compose exec dev fish
```

### Method 4: Docker Compose
```bash
cd container
docker compose up -d
docker compose exec dev fish
```

### Method 5: Distrobox
```bash
# Create from Nix image
./1.ops/distrobox-create.sh

# Or manually:
distrobox create -n diego-dev -i diego-dev:latest
distrobox enter diego-dev
```

---

## Dotfiles Managed

| Tool | Config Location | Key Features |
|------|-----------------|--------------|
| **Fish** | `modules/programs/shells/fish.nix` | Aliases, functions, vi-mode |
| **Bash** | `modules/programs/shells/bash.nix` | Aliases, functions |
| **Starship** | `modules/programs/shells/starship.nix` | Cross-shell prompt |
| **Vim** | `modules/programs/editors/vim.nix` | Leader=Space, statusline |
| **Git** | `modules/programs/git.nix` | 30+ aliases, global ignores |
| **Tmux** | `modules/programs/tmux.nix` | Prefix=C-a, vi-mode |

---

## Environment Variables

```bash
# Set automatically by Nix
EDITOR=vim
CARGO_HOME=$HOME/.cargo
RUSTUP_HOME=$HOME/.rustup
GOPATH=$HOME/go
npm_config_prefix=$HOME/.npm-global
DEVICE=surface|desktop|server
```

---

## Container Images

| Image | Contents | Size (approx) |
|-------|----------|---------------|
| `diego-dev:latest` | Full CLI tools (profiles 1-6) | ~2GB |
| `diego-dev-minimal:latest` | Shell + core only | ~500MB |

---

## Quick Reference

```bash
# Check what's available
nix flake show

# Apply configuration
home-manager switch --flake .#diego@surface

# Build container
nix build .#container
nix build .#container-minimal

# Enter dev shell
nix develop

# Update flake inputs
nix flake update
```

---

## Resources

- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [Nix Package Search](https://search.nixos.org/packages)
- [dockerTools Reference](https://nixos.org/manual/nixpkgs/stable/#sec-pkgs-dockerTools)
