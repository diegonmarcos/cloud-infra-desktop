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
│
├── build.sh                     # Main build script (TUI + CLI)
├── build.json                   # Configuration file
├── build.log                    # Build log (appending)
│
├── a_spec/                      # Documentation
│   ├── spec.md                  # This file (architecture)
│   └── README.md                # Usage guide
│
├── src/                         # ALL source files
│   ├── flake.nix                # Main Nix entry point
│   ├── flake.lock               # Locked dependencies
│   │
│   ├── hosts/                   # Host-specific configs
│   │   ├── surface.nix
│   │   ├── desktop.nix
│   │   └── server.nix
│   │
│   ├── lib/                     # Nix helper functions
│   │   └── default.nix
│   │
│   ├── modules/                 # Nix modules
│   │   ├── common.nix           # Shared config
│   │   ├── profiles/            # 8 package categories
│   │   │   ├── 1-shell-core.nix
│   │   │   ├── 2-dev-languages.nix
│   │   │   ├── 3-build-debug.nix
│   │   │   ├── 4-containers-cloud.nix
│   │   │   ├── 5-security-network.nix
│   │   │   ├── 6-data-science.nix
│   │   │   ├── 7-productivity.nix
│   │   │   └── 8-media-graphics.nix
│   │   ├── programs/            # Dotfile configurations
│   │   │   ├── shells/
│   │   │   │   ├── bash.nix
│   │   │   │   ├── fish.nix
│   │   │   │   ├── zsh.nix
│   │   │   │   └── starship.nix
│   │   │   ├── editors/
│   │   │   │   └── vim.nix
│   │   │   ├── git.nix
│   │   │   └── tmux.nix
│   │   └── dotfiles/            # Extra config files
│   │       ├── fish/
│   │       ├── kde/
│   │       └── konsole/
│   │
│   └── container/               # Container source files
│       ├── compose.yaml         # Podman/Docker Compose
│       ├── Containerfile        # Fallback OCI build
│       ├── distrobox.ini        # Distrobox config
│       └── .containerignore
│
├── dist/                        # Build outputs
│   ├── container-full           # Full container image
│   └── container-minimal        # Minimal container image
│
└── lib/                         # External libraries (future)
```

---

## 8 Profile Categories

| # | Profile | Packages | Description |
|---|---------|----------|-------------|
| 1 | **shell-core** | ~35 | CLI essentials: eza, bat, fd, fzf, ripgrep |
| 2 | **dev-languages** | ~15 | Rust, Go, Node, Python, C/C++, Java |
| 3 | **build-debug** | ~20 | cmake, gdb, valgrind, shellcheck |
| 4 | **containers-cloud** | ~25 | podman, kubectl, terraform, aws/gcp |
| 5 | **security-network** | ~25 | nmap, wireguard, gnupg, tor |
| 6 | **data-science** | ~30 | pandas, torch, jupyter, postgres |
| 7 | **productivity** | ~20 | obsidian, libreoffice, taskwarrior |
| 8 | **media-graphics** | ~25 | ffmpeg, gimp, obs, mpv |

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

## Build Script Usage

### TUI Mode (Interactive)
```bash
./build.sh
```

### CLI Mode (Direct Commands)
```bash
# Nix Operations
./build.sh install              # Install Nix
./build.sh switch [host]        # Apply config (default: surface)
./build.sh update               # Update flake inputs
./build.sh show                 # Show flake outputs
./build.sh develop              # Enter dev shell

# Container Operations
./build.sh container-build [full|minimal]
./build.sh container-load [full|minimal]
./build.sh container-run [full|minimal]
./build.sh container-push <registry>

# Compose Operations
./build.sh compose-up
./build.sh compose-down
./build.sh compose-shell

# Distrobox Operations
./build.sh distrobox-create [name]
./build.sh distrobox-enter [name]
./build.sh distrobox-remove [name]

# Utilities
./build.sh status               # System status
./build.sh clean                # Clean build artifacts
./build.sh log                  # View build log
./build.sh clear-log            # Clear build log
./build.sh --help               # Show help
```

---

## 5 Deployment Methods

### Method 1: Pure Nix (Native)
```bash
./build.sh install
./build.sh switch surface
```

### Method 2: Nix-Built Container
```bash
./build.sh container-build
./build.sh container-load
./build.sh container-run
```

### Method 3: Podman Compose
```bash
./build.sh container-build
./build.sh container-load
./build.sh compose-up
./build.sh compose-shell
```

### Method 4: Docker Compose
```bash
./build.sh container-build
./build.sh container-load
./build.sh compose-up
./build.sh compose-shell
```

### Method 5: Distrobox
```bash
./build.sh container-build
./build.sh container-load
./build.sh distrobox-create
distrobox enter diego-dev
```

---

## Configuration

### build.json
```json
{
  "project": { "name": "diego-dev", "version": "1.0.0" },
  "paths": { "src": "src", "dist": "dist", "lib": "lib" },
  "defaults": { "user": "diego", "host": "surface", "preset": "full" },
  "container": { "image_name": "diego-dev", "image_tag": "latest" }
}
```

---

## Dotfiles Managed

| Tool | Location | Key Features |
|------|----------|--------------|
| **Fish** | `src/modules/programs/shells/fish.nix` | Aliases, vi-mode |
| **Bash** | `src/modules/programs/shells/bash.nix` | Aliases, functions |
| **Starship** | `src/modules/programs/shells/starship.nix` | Prompt |
| **Vim** | `src/modules/programs/editors/vim.nix` | Leader=Space |
| **Git** | `src/modules/programs/git.nix` | 30+ aliases |
| **Tmux** | `src/modules/programs/tmux.nix` | Prefix=C-a |

---

## Notes

- **src/** contains ALL source files (nix, container, dotfiles)
- **dist/** contains build outputs (container images)
- **lib/** reserved for future external libraries
- **build.log** appends all build activity
- Nix handles package management (downloads to /nix/store)

---

## Resources

- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [Nix Package Search](https://search.nixos.org/packages)
- [dockerTools Reference](https://nixos.org/manual/nixpkgs/stable/#sec-pkgs-dockerTools)
