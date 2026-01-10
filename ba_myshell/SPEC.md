# MyShell - Architecture Specification

## Overview

MyShell creates an **isolated shell environment** using `nix-shell` from the self-contained `nix-portable` binary. The environment provides modern shell tools without requiring root access or system-wide installation.

---

## Design Goals

1. **Isolation** - Separate HOME directory from host system
2. **Portability** - Self-contained, works on any Linux x86_64/ARM64
3. **Reproducibility** - Same tools and versions everywhere
4. **POSIX Compliance** - Works with any `/bin/sh` compatible shell
5. **Offline Operation** - Bundled packages, no network required

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         HOST SYSTEM                                  │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  Terminal Emulator (Konsole, Alacritty, etc)                  │  │
│  │  └─> System Shell (/bin/sh, bash, zsh)                        │  │
│  │      └─> ./myshell                                            │  │
│  │          │                                                    │  │
│  │          ▼                                                    │  │
│  │  ┌─────────────────────────────────────────────────────────┐  │  │
│  │  │           NIX-PORTABLE ENVIRONMENT                      │  │  │
│  │  │                                                         │  │  │
│  │  │  HOME: ~/.temp/home-tmp (isolated)                      │  │  │
│  │  │     or /home/user (mirror)                              │  │  │
│  │  │                                                         │  │  │
│  │  │  PATH: /nix/store/...:$PATH                             │  │  │
│  │  │                                                         │  │  │
│  │  │  ┌───────────────────────────────────────────────────┐  │  │  │
│  │  │  │  FISH SHELL (default)                             │  │  │  │
│  │  │  │  • starship prompt                                │  │  │  │
│  │  │  │  • eza, bat, fzf, zoxide                          │  │  │  │
│  │  │  │  • Profile-specific tools                         │  │  │  │
│  │  │  │                                                   │  │  │  │
│  │  │  │  Can switch to: zsh, bash                         │  │  │  │
│  │  │  └───────────────────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Components

### 1. nix-portable

Self-contained Nix binary that requires no system installation.

| Property | Value |
|----------|-------|
| Binary | `_bundled/nix-portable` (~65MB) |
| Store | `_bundled/.nix-portable/` |
| Config | `_bundled/config/shell.nix` |

**Source**: [github.com/DavHau/nix-portable](https://github.com/DavHau/nix-portable)

### 2. Isolation Layer

HOME directory isolation via environment variable.

| Mode | `$HOME` | Access |
|------|---------|--------|
| **Isolated** | `~/.temp/home-tmp` | Real home via `~/real-home` symlink |
| **Mirror** | `/home/user` | Direct access to real home |

In isolated mode:
- README.md copied into isolated home for reference
- `~/real-home` symlink points to real home directory

### 3. nix-shell

Nix's development shell mechanism that provides reproducible environments.

```
shell.nix → nix-shell → Modified PATH → Tools available
```

### 4. Profiles

Three tiered profiles with cumulative tool sets:

```
┌─────────────────────────────────────────────────────────────────────┐
│  BASIC PROFILE (~2-3GB)                                             │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  nodejs, python3, gcloud, rclone, wireguard                   │  │
│  │  ┌─────────────────────────────────────────────────────────┐  │  │
│  │  │  MINIMUM PROFILE (~500MB)                               │  │  │
│  │  │  ┌───────────────────────────────────────────────────┐  │  │  │
│  │  │  │  git, vim, ripgrep, fd, curl, wget, jq, yazi      │  │  │  │
│  │  │  │  ┌─────────────────────────────────────────────┐  │  │  │  │
│  │  │  │  │  SHELL PROFILE (~200MB)                     │  │  │  │  │
│  │  │  │  │  fish, zsh, starship                        │  │  │  │  │
│  │  │  │  │  eza, bat, fzf, zoxide                      │  │  │  │  │
│  │  │  │  └─────────────────────────────────────────────┘  │  │  │  │
│  │  │  └───────────────────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Isolation Modes

### Isolated Mode (Default)

```
Real filesystem:                    MyShell view:
/home/user/                         $HOME = ~/.temp/home-tmp/
├── .config/                        ├── README.md     (copied from dist/)
├── .cache/                         ├── real-home/  → /home/user/ (symlink)
├── Documents/                      ├── .config/      (empty)
└── ...                             └── .cache/       (empty)
```

**Characteristics:**
- Clean environment on each session
- No config pollution
- README.md available at `~/README.md`
- Real home accessible via `~/real-home`

### Mirror Mode

```
Real filesystem:                    MyShell view:
/home/user/                         $HOME = /home/user/
├── .config/                        ├── .config/      (same)
├── .cache/                         ├── .cache/       (same)
├── Documents/                      ├── Documents/    (same)
└── ...                             └── ...           (same)
```

**Characteristics:**
- Direct access to all files
- Configs shared with system
- Changes persist immediately

---

## Directory Structure

### Source Tree

```
myshell/
├── README.md              # User documentation
├── SPEC.md                # This file
├── OPS.md                 # Runbook
├── build.sh               # Build script (POSIX)
├── bin/
│   └── nix-portable       # Nix binary (65MB)
└── src/
    ├── shell-profile.nix      # Shell Profile definition
    ├── minimum-profile.nix    # Minimum Profile definition
    └── basic-profile.nix      # Basic Profile definition
```

### Distribution Tree

Each profile in `dist/` is self-contained:

```
dist/<profile>/
├── myshell                # Main launcher (POSIX shell)
├── fish-shell             # Fish shortcut
├── zsh-shell              # Zsh shortcut
├── README.md              # Tools reference (copied to isolated home)
└── _bundled/
    ├── nix-portable       # Nix binary
    ├── config/
    │   └── shell.nix      # Profile definition
    └── .nix-portable/     # Complete Nix store
        └── nix/
            └── store/     # All packages
```

---

## Data Flow

### Build Process

```
┌──────────────┐     ┌─────────────────┐     ┌──────────────────┐
│  build.sh    │────>│  nix-portable   │────>│  ~/.nix-portable │
│  <profile>   │     │  nix-shell      │     │  (download pkgs) │
└──────────────┘     └─────────────────┘     └────────┬─────────┘
                                                      │
                     ┌─────────────────┐              │
                     │  dist/<profile> │<─────────────┘
                     │  (copy store)   │
                     └─────────────────┘
```

### Runtime Flow

```
┌──────────────┐     ┌─────────────────┐     ┌──────────────────┐
│  ./myshell   │────>│  Setup HOME     │────>│  nix-portable    │
│  [--mode]    │     │  Copy README.md │     │  nix-shell       │
└──────────────┘     └─────────────────┘     └────────┬─────────┘
                                                      │
                     ┌─────────────────┐              │
                     │  fish shell     │<─────────────┘
                     │  (with tools)   │
                     └─────────────────┘
```

---

## Package Priority

When inside MyShell, PATH is modified:

```
/nix/store/.../bin       ← Nix packages (FIRST)
/nix/store/.../bin
...
/usr/local/bin           ← System packages (LAST)
/usr/bin
/bin
```

**Result**: Nix tools take precedence over system tools.

---

## Shell Configuration

### Default Shell: Fish

Fish is the default shell with:
- Starship prompt integration
- Syntax highlighting (built-in)
- Autosuggestions (built-in)

### Alternative Shells

Bash and zsh are available from the launcher or from within fish:

```bash
./myshell --zsh    # Start with zsh
./myshell --bash   # Start with bash

# Or from inside fish:
$ zsh
$ bash
```

All shells share the same Nix environment (same tools, same PATH).

---

## Limitations

1. **Linux only** - nix-portable requires Linux kernel features
2. **x86_64/ARM64 only** - Architecture-specific binaries
3. **Large bundled size** - Nix store includes all dependencies
4. **No namespace isolation** - HOME separation only, not full sandbox

---

## References

- [nix-portable](https://github.com/DavHau/nix-portable)
- [Nix Pills](https://nixos.org/guides/nix-pills/)
- [Fish Shell](https://fishshell.com/)
- [Starship Prompt](https://starship.rs/)
