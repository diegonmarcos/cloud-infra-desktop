# Nix Home Manager - Standalone Multi-Distro Setup

Portable, declarative user environment that works on any Linux distribution (Kubuntu, Arch, Fedora, etc.) without requiring NixOS.

## Features

- **Standalone**: Works on any Linux distro without NixOS
- **Modular Profiles**: 8 categories with toggle system
- **Full Dotfiles**: Bash, Zsh, Fish, Starship, Vim, Git, Tmux
- **Host-Specific**: Different configs for surface/desktop/server
- **Reproducible**: Same environment across machines

## Quick Start

### Installation

```bash
cd /home/diego/mnt_git/unix/a_kubuntu
./scripts/install.sh surface
```

This will:
1. Install Nix (if not present)
2. Enable flakes
3. Apply Home Manager configuration
4. Install all packages for enabled profiles

### Daily Usage

```bash
# Rebuild after changes
./scripts/switch.sh

# Update all packages
./scripts/update.sh

# Manual rebuild
home-manager switch --flake .#diego@surface
```

## Profiles

### 8 Profile Categories

| Profile | Description | Key Tools |
|---------|-------------|-----------|
| **base** | Essential CLI | eza, bat, fd, ripgrep, fzf, zoxide, btop, rsync, gh |
| **dev-langs** | Languages | Rust, Go, Node, Python, C/C++, Java |
| **dev-tools** | Build Tools | cmake, ninja, gdb, valgrind, podman, shellcheck |
| **security** | Security | tor, wireguard, nmap, gnupg, age, pass |
| **productivity** | Office | libreoffice, obsidian, okular, taskwarrior |
| **media** | Multimedia | ffmpeg, gimp, mpv, obs-studio, imagemagick |
| **cloud** | Cloud/DevOps | kubectl, terraform, ansible, gcloud, awscli |
| **data-science** | ML/AI | numpy, pandas, jupyter, torch, scikit-learn |

### Host Configurations

| Host | Enabled Profiles |
|------|------------------|
| **surface** | ALL (base, dev-langs, dev-tools, security, productivity, cloud, data-science) |
| **desktop** | base, dev-langs, dev-tools, media, productivity, cloud |
| **server** | base, cloud |

## Customization

### Adding New Profile

1. Create `modules/profiles/myprofile.nix`
2. Add packages to `home.packages`
3. Enable in `flake.nix`:

```nix
"diego@myhost" = mkHost ./hosts/myhost.nix [
  "base"
  "myprofile"
];
```

### Modifying Dotfiles

Edit files in `modules/programs/`:
- `shells/bash.nix` - Bash configuration
- `shells/starship.nix` - Prompt
- `editors/vim.nix` - Vim configuration
- `git.nix` - Git config
- `tmux.nix` - Tmux (prefix: C-a)

### Host-Specific Settings

Edit `hosts/surface.nix` (or desktop/server) to add host-specific packages.

## Key Bindings

### Tmux (Prefix: C-a)

```
C-a |       Split horizontal
C-a -       Split vertical
C-a h/j/k/l Navigate panes
C-a H/J/K/L Resize panes
C-a r       Reload config
```

### Vim (Leader: Space)

```
<leader>w   Save
<leader>q   Quit
<leader>bn  Next buffer
<leader>bp  Previous buffer
C-h/j/k/l   Navigate windows
```

### Shell Aliases

```bash
ls → eza --icons
cat → bat
grep → rg
find → fd
docker → podman

gs → git status -sb
ga → git add
gc → git commit
gp → git push
```

## Directory Structure

```
a_kubuntu/
├── flake.nix          # Main entry point
├── lib/               # Helper functions
├── modules/
│   ├── common.nix     # Shared config
│   ├── profiles/      # 8 package profiles
│   └── programs/      # Dotfile modules
├── hosts/             # Host-specific configs
└── scripts/           # Management scripts
```

## Environment Variables

Set automatically:

```bash
$CARGO_HOME         # Rust packages
$GOPATH             # Go packages
$npm_config_prefix  # npm global
$DEVICE             # surface/desktop/server
$PROFILE            # auth (from dual-profile system)
```

## Troubleshooting

### Nix not found after install
```bash
source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
```

### Permission denied on scripts
```bash
chmod +x scripts/*.sh
```

### Profile not found
```bash
# Check available configs
nix flake show .

# Use default
home-manager switch --flake .#diego
```

### Build fails
```bash
# Clean and retry
nix-collect-garbage
./scripts/switch.sh
```

## Integration

### With Existing NixOS

This setup is independent of `/home/diego/mnt_git/unix/a_nixos_host/`. Both can coexist:
- NixOS manages system packages
- Home Manager manages user packages

### With Existing Dotfiles

Existing dotfiles at `../0_spec/z_dotfiles_src/` are preserved as reference. Home Manager now manages dotfiles declaratively.

## Notes

- **Unfree packages**: Enabled (vscode, discord, etc.)
- **Nix version**: 24.11 (stable)
- **Home Manager**: Standalone mode (no NixOS required)
- **State version**: 24.11 (do not change)

## Resources

- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [Nix Package Search](https://search.nixos.org/packages)
- [Nix Options Search](https://search.nixos.org/options)

---

**Created**: 2026-01-07
**Author**: Diego Nepomuceno Marcos
**License**: Personal use
