# MyShell

A portable, self-contained shell environment using **nix-portable** with **fish** as default shell.

```
╔════════════════════════════════════════╗
║  MyShell - Portable Nix Shell          ║
║  100% POSIX • Self-Contained • Offline ║
╚════════════════════════════════════════╝
```

---

## Quick Start

```bash
# 1. Build a profile
./build.sh minimum

# 2. Run
./dist/minimum/myshell
```

---

## Build Profiles

```bash
./build.sh shell      # ~200MB  - Shell essentials
./build.sh minimum    # ~500MB  - + Dev tools
./build.sh basic      # ~2-3GB  - + Runtimes, Cloud, AI
./build.sh all        # Build all three
```

Each profile in `dist/` is **self-contained** and works offline.

---

## Usage

```bash
./dist/minimum/myshell              # Start fish (default, isolated)
./dist/minimum/myshell --mirror     # Start fish (use real $HOME)
./dist/minimum/myshell --zsh        # Start zsh instead
./dist/minimum/myshell --bash       # Start bash instead
./dist/minimum/myshell -c "cmd"     # Run single command
```

**Shortcuts:**
```bash
./dist/minimum/fish-shell           # Quick fish launcher
./dist/minimum/zsh-shell            # Quick zsh launcher
```

---

## Modes

| Mode | `$HOME` | Use Case |
|------|---------|----------|
| **Isolated** (default) | `~/.temp/home-tmp` | Clean environment, no pollution |
| **Mirror** (`--mirror`) | `/home/diego` | Access real configs and files |

In isolated mode, your real home is accessible via `~/real-home`.

---

## Tools Reference

### Shell Profile (~200MB)

Modern shell experience with essential tools.

```
╔═══════════════════════════════════════════════════════════════════╗
║  SHELLS                                                           ║
╠═══════════════════════════════════════════════════════════════════╣
║  fish      │ Friendly Interactive Shell (default)                 ║
║  zsh       │ Z Shell with powerful features                       ║
║  bash      │ Bourne Again Shell                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║  PROMPT & NAVIGATION                                              ║
╠═══════════════════════════════════════════════════════════════════╣
║  starship  │ Cross-shell prompt with git/env info                 ║
║  zoxide    │ Smart cd - learns your habits          │ z <dir>     ║
║  fzf       │ Fuzzy finder for files and history     │ fzf         ║
╠═══════════════════════════════════════════════════════════════════╣
║  FILE VIEWING                                                     ║
╠═══════════════════════════════════════════════════════════════════╣
║  eza       │ Modern ls with icons and git status    │ eza -la     ║
║  bat       │ cat with syntax highlighting           │ bat file    ║
╚═══════════════════════════════════════════════════════════════════╝
```

---

### Minimum Profile (~500MB)

Everything in Shell + development essentials.

```
╔═══════════════════════════════════════════════════════════════════╗
║  Includes all Shell Profile tools                                 ║
╠═══════════════════════════════════════════════════════════════════╣
║  DEVELOPMENT                                                      ║
╠═══════════════════════════════════════════════════════════════════╣
║  git       │ Version control system                 │ git status  ║
║  vim       │ Modal text editor                      │ vim file    ║
╠═══════════════════════════════════════════════════════════════════╣
║  SEARCH                                                           ║
╠═══════════════════════════════════════════════════════════════════╣
║  ripgrep   │ Fast grep alternative                  │ rg pattern  ║
║  fd        │ Fast find alternative                  │ fd name     ║
╠═══════════════════════════════════════════════════════════════════╣
║  NETWORK                                                          ║
╠═══════════════════════════════════════════════════════════════════╣
║  curl      │ HTTP client                            │ curl URL    ║
║  wget      │ Download files                         │ wget URL    ║
╠═══════════════════════════════════════════════════════════════════╣
║  DATA & FILES                                                     ║
╠═══════════════════════════════════════════════════════════════════╣
║  jq        │ JSON processor                         │ jq '.'      ║
║  yazi      │ Terminal file manager                  │ yazi        ║
╚═══════════════════════════════════════════════════════════════════╝
```

---

### Basic Profile (~2-3GB)

Full development environment with runtimes and cloud tools.

```
╔═══════════════════════════════════════════════════════════════════╗
║  Includes all Minimum Profile tools                               ║
╠═══════════════════════════════════════════════════════════════════╣
║  RUNTIMES                                                         ║
╠═══════════════════════════════════════════════════════════════════╣
║  nodejs    │ Node.js 20.x + npm                     │ node app.js ║
║  python3   │ Python 3.11 + pip                      │ python3     ║
╠═══════════════════════════════════════════════════════════════════╣
║  CLOUD                                                            ║
╠═══════════════════════════════════════════════════════════════════╣
║  gcloud    │ Google Cloud Platform CLI              │ gcloud ...  ║
║  rclone    │ Cloud storage sync (40+ providers)     │ rclone sync ║
╠═══════════════════════════════════════════════════════════════════╣
║  VPN                                                              ║
╠═══════════════════════════════════════════════════════════════════╣
║  wireguard │ Modern VPN client                      │ wg-quick up ║
╠═══════════════════════════════════════════════════════════════════╣
║  AI                                                               ║
╠═══════════════════════════════════════════════════════════════════╣
║  claude    │ Claude Code - AI coding assistant      │ claude      ║
╚═══════════════════════════════════════════════════════════════════╝
```

---

## Profile Comparison

| Feature | Shell | Minimum | Basic |
|---------|:-----:|:-------:|:-----:|
| **Size** | ~200MB | ~500MB | ~2-3GB |
| fish, zsh, bash | * | * | * |
| starship, eza, bat | * | * | * |
| fzf, zoxide | * | * | * |
| git, vim | | * | * |
| ripgrep, fd | | * | * |
| curl, wget, jq | | * | * |
| yazi | | * | * |
| Node.js, Python | | | * |
| gcloud, rclone | | | * |
| wireguard | | | * |
| Claude Code | | | * |

---

## Welcome Message

When you start MyShell, you'll see:

```
╔════════════════════════════════════════╗
║  MyShell - ISOLATED Mode               ║
║  Profile: Minimum (~500MB)             ║
╚════════════════════════════════════════╝

🏠 Isolated HOME: /home/diego/.temp/home-tmp
🔗 Real home: ~/real-home → /home/diego

Available shells:
  • fish  - Friendly Interactive Shell (default)
  • zsh   - Z Shell
  • bash  - Bourne Again Shell

Tools included:
  • Shell: starship, eza, bat, fzf, zoxide
  • Dev: git, vim, ripgrep, fd
  • Network: curl, wget
  • Data: jq, yazi

✓ Minimum Profile ready!
```

---

## Project Structure

```
myshell/
├── README.md            # User documentation (this file)
├── SPEC.md              # Architecture design
├── OPS.md               # Runbook
├── build.sh             # Build script (POSIX)
├── bin/
│   └── nix-portable     # Portable Nix binary (65MB)
├── src/                 # Nix profile definitions
│   ├── shell-profile.nix
│   ├── minimum-profile.nix
│   └── basic-profile.nix
└── dist/                # Built distributions (self-contained)
    ├── shell/           # ~200MB
    │   ├── myshell
    │   ├── fish-shell
    │   ├── zsh-shell
    │   └── _bundled/    # nix-portable + .nix-portable store
    ├── minimum/         # ~500MB
    └── basic/           # ~2-3GB
```

---

## Portability

Create a portable archive:

```bash
tar czf myshell-minimum.tar.gz dist/minimum/
```

Transfer to any Linux x86_64/ARM64 system and run:

```bash
tar xzf myshell-minimum.tar.gz
./dist/minimum/myshell
```

No installation required. Works offline.

---

## Requirements

- **POSIX shell** - Any `/bin/sh` compatible
- **Linux** x86_64 or ARM64
- **Disk space** - Varies by profile

---

## Documentation

| Document | Description |
|----------|-------------|
| [README.md](./README.md) | User documentation (this file) |
| [SPEC.md](./SPEC.md) | Architecture and design |
| [OPS.md](./OPS.md) | Runbook and operations |

---

## License

MIT License. Individual tools have their own licenses.
