# Shell Configuration

Modular shell configuration for Bash, Zsh, and Fish with unified features.

## Structure

```
shell/
├── home.nix              # NixOS Home Manager integration
├── home-simple.nix       # Simple file copy approach
├── profile               # Shared login profile
├── README.md             # This file
│
├── bash/
│   ├── bashrc            # Main config (sources modules)
│   ├── aliases.bash      # All aliases
│   ├── functions.bash    # All functions
│   ├── integrations.bash # External tools (starship, wakatime, nvm, cargo)
│   └── startup.bash      # Welcome screen with system info
│
├── zsh/
│   ├── zshrc             # Main config (sources modules)
│   ├── aliases.zsh       # All aliases
│   ├── functions.zsh     # All functions
│   ├── functions-c-dev.zsh # C development functions
│   ├── integrations.zsh  # External tools (p10k, oh-my-zsh, wakatime, nvm)
│   ├── startup.zsh       # Welcome screen with system info
│   ├── p10k.zsh          # Powerlevel10k theme config
│   └── zprofile          # Login profile
│
└── fish/
    ├── config.fish       # Main config
    ├── conf.d/           # Auto-sourced configs (alphabetical order)
    │   ├── 00-aliases.fish
    │   ├── 10-integrations.fish
    │   ├── 99-startup.fish
    │   ├── chrome-dev.fish
    │   ├── nix.fish
    │   ├── rustup.fish
    │   └── wakatime.fish
    ├── functions/        # Auto-loaded functions (one per file)
    │   ├── backup.fish
    │   ├── ccusage-models.fish
    │   ├── cpucap.fish
    │   ├── duh.fish
    │   ├── extract.fish
    │   ├── fisher.fish
    │   ├── gcam.fish
    │   ├── git_current_branch.fish
    │   ├── gpsh.fish
    │   ├── hg.fish
    │   ├── localip.fish
    │   ├── mkcd.fish
    │   ├── mkd.fish
    │   ├── myhelp.fish
    │   ├── path.fish
    │   ├── pyp.fish
    │   ├── qfind.fish
    │   ├── show_aliases.fish
    │   └── show_functions.fish
    └── fish_plugins      # Fisher plugin list
```

## Features (All Shells)

### Aliases

| Category | Aliases |
|----------|---------|
| **Python** | `py`, `python`, `pip`, `ppy` |
| **Navigation** | `..`, `...`, `....`, `.....` |
| **Listing** | `ll`, `la`, `l`, `lh`, `lt` |
| **Git Basic** | `gs`, `ga`, `gaa`, `gc`, `gcm`, `gp`, `gl`, `gla`, `gd`, `gds`, `gco`, `gb`, `gba`, `gpl`, `gcl`, `gst`, `gstp` |
| **Git Quick** | `push` (add+commit+push) |
| **Safety** | `cp`, `mv`, `rm` (all with `-i`) |
| **System** | `df`, `du`, `duh`, `free`, `psg`, `mem` |
| **Network** | `ports`, `myip`, `localip`, `ping` |
| **Docker** | `dps`, `dpsa`, `dcu`, `dcd`, `dlog`, `dex` |
| **Dev** | `serve`, `jn` |
| **Browser** | `chrome_no_CORS`, `chromium_no_CORS`, `brave_no_CORS` |
| **Misc** | `c`, `h`, `hg`, `path`, `reload`, `week`, `timer` |
| **Custom** | `gdrive`, `gdrive_mount`, `gdrive_umount`, `mem_recover`, `mem_usage` |

### Functions

| Function | Description |
|----------|-------------|
| `mkcd <dir>` | Create directory and cd into it |
| `mkd <dir>` | Alias for mkcd |
| `extract <file>` | Extract any archive format |
| `qfind <pattern>` | Quick find by filename |
| `backup <file>` | Backup file with timestamp |
| `gcam <msg>` | Git add all + commit |
| `gpsh` | Git push to current branch |
| `cpucap` | Show CPU frequency per core |
| `pyp <pkg> [args]` | Poetry package runner |
| `myhelp` | Show all aliases and functions |
| `show_aliases` | List all aliases |
| `show_functions` | List all functions |

### C Development (Zsh only)

| Function | Description |
|----------|-------------|
| `c <file>` | Compile C file |
| `cx <file> [args]` | Compile and execute |
| `cv <file> [test] [stdin] [args]` | Compile with Valgrind |
| `cl <file>` | Compile with mylibc |
| `clx <file> [args]` | Compile with mylibc and execute |
| `clv <file> [args]` | Compile with mylibc and Valgrind |
| `cdb <file>` | Debug with lldb |
| `cldb <file>` | Debug with lldb + mylibc |
| `cldbg <file>` | Debug with gdb + mylibc |
| `myhelp_c` | Show C dev help |

### Integrations

| Tool | Bash | Zsh | Fish |
|------|:----:|:---:|:----:|
| **Starship** | ✅ | ❌ (uses p10k) | ✅ |
| **Powerlevel10k** | ❌ | ✅ | ❌ |
| **Oh-My-Zsh** | ❌ | ✅ | ❌ |
| **WakaTime** | ✅ | ✅ (plugin) | ✅ |
| **NVM** | ✅ | ✅ | ✅ (via bass) |
| **Cargo/Rust** | ✅ | ✅ | ✅ |
| **FZF** | ✅ | ✅ | ✅ |
| **Direnv** | ✅ | ✅ | ✅ |
| **Zoxide** | ✅ | ✅ | ✅ |

### Welcome Screen

All shells display on startup:
- System info (OS, kernel, hostname, uptime, CPU, memory)
- Network info (IP, gateway)
- Disk usage
- Mounted rclone drives
- Quick reference cheatsheet
- ASCII art

## Usage

### With NixOS Home Manager

```nix
# In your home.nix
imports = [ ./shell/home.nix ];
```

### Standalone

```bash
# Bash
ln -sf /path/to/shell/bash/bashrc ~/.bashrc

# Zsh
ln -sf /path/to/shell/zsh/zshrc ~/.zshrc
ln -sf /path/to/shell/zsh/p10k.zsh ~/.p10k.zsh

# Fish
ln -sf /path/to/shell/fish/config.fish ~/.config/fish/config.fish
ln -sf /path/to/shell/fish/conf.d ~/.config/fish/conf.d
ln -sf /path/to/shell/fish/functions ~/.config/fish/functions
```

## Local Customizations

Each shell supports local overrides (not tracked in git):
- Bash: `~/.bashrc.local`
- Zsh: `~/.zshrc.local`
- Fish: `~/.config/fish/config.fish.local`

## Commands

| Command | Description |
|---------|-------------|
| `myhelp` | Show all aliases and functions |
| `reload` | Reload shell configuration |
| `editbash` / `editzsh` / `editfish` | Edit main config |
| `editalias` | Edit aliases file |

## Dependencies

The configs reference these tools (installed via home.nix):
- starship (prompt for bash/fish)
- oh-my-zsh + powerlevel10k (zsh prompt)
- wakatime (coding time tracking)
- ripgrep, fd, bat, eza, fzf, jq, zoxide (CLI tools)
- python3, poetry (dev tools)
