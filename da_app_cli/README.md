# Diego's CLI Development Container

```
┌───────────────────────────────────────────────────────┐
│ NIX (pinned, stable, heavy)                           │
│ ├── Compilers: gcc, clang, rustc, go, java            │
│ ├── Big libs: openssl, zlib, glibc, llvm              │
│ ├── System tools: git, curl, coreutils                │
│ ├── Python 3.11 interpreter                           │
│ └── Poetry itself                                     │
│                                                       │
│   ┌───────────────────────────────────────────────┐   │
│   │ POETRY (fast-moving, project-specific)        │   │
│   │ ├── pypi packages                             │   │
│   │ ├── Project deps (numpy, opencv, etc.)        │   │
│   │ └── Lock file per project                     │   │
│   └───────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────┘
                        │
                        ▼ OCI image
                 ┌─────────────┐
                 │   Podman    │  (rootless)
                 └─────────────┘
                        │
                        ▼
                 ┌─────────────┐
                 │  Distrobox  │  (host integration)
                 └─────────────┘
```

## Structure

```
app_cli/
├── nix/
│   ├── container.nix     # All CLI tools definition
│   └── flake.nix         # Reproducible build (pins nixpkgs)
├── poetry_venv_1/
│   └── pyproject.toml    # Python dependencies (existing)
├── scripts/
│   └── setup.sh          # Build & setup automation
└── README.md
```

## Quick Start

```bash
# Full setup (build + load + create + poetry)
./scripts/setup.sh

# Enter the container
distrobox enter dev

# Use Poetry for Python
cd ~/app_cli/poetry_venv_1_venv_1 && poetry shell
```

## Commands

| Command | Description |
|---------|-------------|
| `./scripts/setup.sh full` | Complete setup from scratch |
| `./scripts/setup.sh rebuild` | Rebuild after nix changes |
| `./scripts/setup.sh build` | Only build Nix image |
| `./scripts/setup.sh load` | Only load into Podman |
| `./scripts/setup.sh create` | Only create Distrobox |
| `./scripts/setup.sh poetry` | Only setup Poetry env |
| `./scripts/setup.sh export` | Export tools to host |

## What's Included

### Nix (System Tools)

| Category | Packages |
|----------|----------|
| **Shells** | bash, zsh, fish, starship |
| **C/C++** | gcc, clang, make, cmake, ninja, meson |
| **Debug** | gdb, lldb, valgrind, strace |
| **Python** | python3.11, poetry |
| **Node.js** | nodejs 20, npm, yarn |
| **Rust** | rustup |
| **Go** | go |
| **Java** | openjdk 21 |
| **Ruby** | ruby, jekyll |
| **Git** | git, gh, git-lfs |
| **CLI** | ripgrep, fd, bat, fzf, jq, yazi |
| **Network** | curl, wget, nmap, rclone, rsync |
| **Archive** | tar, zip, unzip, 7z, zstd |

### Poetry (Python Packages)

| Category | Packages |
|----------|----------|
| **Data** | numpy, scipy |
| **CV** | opencv-python, opencv-contrib-python |
| **Docs** | python-docx, openpyxl, lxml |
| **QR** | qrcode, pyzbar |
| **Dev** | pytest, black, ruff, mypy |
| **Jupyter** | jupyterlab (optional group) |

## Adding Packages

### Add Nix package

Edit `nix/container.nix`, add to `paths`:
```nix
pkgs.newpackage
```

Then rebuild:
```bash
./scripts/setup.sh rebuild
```

### Add Python package

```bash
distrobox enter dev
cd ~/app_cli/poetry_venv_1
poetry add newpackage
```

## Export Tools to Host

Run CLI tools directly from host without entering container:

```bash
# Export a tool
distrobox enter dev -- distrobox-export --bin /bin/rg

# Now use it on host
rg "search term"
```

## Prerequisites

- **Nix**: `curl -L https://nixos.org/nix/install | sh`
- **Podman**: `sudo apt install podman`
- **Distrobox**: `curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh`
