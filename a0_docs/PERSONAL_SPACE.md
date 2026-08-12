# Personal Space Specification

> **User**: user (UID 1000)
> **Home**: /home/user (persisted via @user/home subvolume)
> **Organization**: Tools + Configs + Mounts + Vault

---

## Personal Space Overview

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           PERSONAL SPACE                                      │
│                           /home/user                                          │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐  ┌────────────┐ │
│  │     TOOLS      │  │    CONFIGS     │  │     MOUNTS     │  │   VAULT    │ │
│  │                │  │                │  │                │  │            │ │
│  │  From Nix      │  │  ~/.config     │  │  ~/mnt_*       │  │  ~/vault   │ │
│  │  From Flatpak  │  │  ~/.local      │  │                │  │            │ │
│  │  From Distrobox│  │  Dotfiles      │  │  Cloud drives  │  │  Encrypted │ │
│  │                │  │                │  │  Git repos     │  │  LUKS-in-  │ │
│  │  CLI + GUI     │  │  Shell + Apps  │  │  Sync folders  │  │  LUKS      │ │
│  │                │  │                │  │                │  │            │ │
│  └────────────────┘  └────────────────┘  └────────────────┘  └────────────┘ │
│                                                                              │
│  SOURCE:            PERSIST:            RUNTIME:            MANUAL:          │
│  /nix/store         @user/home          fuse mounts         tomb open        │
│  ~/.var/app         subvolume           rclone/sshfs                         │
│  distrobox homes                                                             │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 1. Tools

### Tool Sources

| Source | Trust | Location | Management |
|--------|-------|----------|------------|
| **Nix Native** | 100% | /nix/store → PATH | configuration.nix |
| **Flatpak** | 60% | /var/lib/flatpak | flatpak install |
| **Distrobox** | 80% | Container images | distrobox create |
| **User scripts** | 100% | ~/.local/bin | Manual |

### Nix Native Tools (via configuration.nix)

```nix
environment.systemPackages = with pkgs; [
  # Core CLI
  vim neovim git curl wget htop btop tree jq yq
  fd ripgrep fzf tmux screen zoxide starship eza bat

  # System
  pciutils usbutils lsof parted btrfs-progs cryptsetup

  # Network
  nmap dig tcpdump iproute2 wireguard-tools

  # Development
  gcc gnumake cmake
  python3 python312Packages.pip
  nodejs_22 nodePackages.npm
  rustc cargo go

  # Cloud
  google-cloud-sdk rclone

  # Containers
  docker-compose podman-compose buildah skopeo dive distrobox

  # Desktop
  firefox chromium vscode kate konsole dolphin

  # Security
  tomb age pinentry-curses
];
```

### Flatpak Tools (GUI apps)

```bash
# Install from Flathub
flatpak install flathub org.mozilla.firefox
flatpak install flathub com.discordapp.Discord
flatpak install flathub com.slack.Slack
flatpak install flathub com.spotify.Client
flatpak install flathub com.visualstudio.code

# Permission manager
flatpak install flathub com.github.tchx84.Flatseal
```

### Distrobox Tools (dev environments)

```bash
# Arch Linux (rolling, latest packages)
distrobox create --name arch-dev --image archlinux:latest
distrobox enter arch-dev
# Inside: pacman -S base-devel rust nodejs python

# Fedora (stable, enterprise tools)
distrobox create --name fedora-dev --image fedora:latest
distrobox enter fedora-dev
# Inside: dnf groupinstall "Development Tools"

# Ubuntu LTS (Debian ecosystem)
distrobox create --name ubuntu-dev --image ubuntu:24.04
distrobox enter ubuntu-dev
# Inside: apt install build-essential
```

### User Scripts (~/.local/bin)

```
~/.local/bin/
├── backup-vault           # Backup vault to cloud
├── mount-clouds           # Mount rclone remotes
├── sync-repos             # Pull all git repos
├── update-system          # nixos-rebuild + flatpak update
└── workspace-setup        # Initialize dev environment
```

---

## 2. Configs

### Directory Structure

```
~/.config/                              # XDG config directory
├── fish/                               # Fish shell
│   ├── config.fish                     # Main config
│   ├── functions/                      # Custom functions
│   └── completions/                    # Tab completions
├── starship.toml                       # Prompt configuration
├── nvim/                               # Neovim
│   └── init.lua                        # Lua config
├── git/                                # Git (XDG location)
│   ├── config                          # Git config
│   └── ignore                          # Global gitignore
├── kde*/ plasma*/                      # KDE Plasma settings
├── Code/                               # VSCode settings
│   └── User/
│       ├── settings.json
│       └── keybindings.json
└── containers/                         # Podman config
    └── containers.conf

~/.local/                               # XDG local data
├── bin/                                # User scripts
├── share/
│   ├── fish/fish_history               # Fish history
│   ├── applications/                   # .desktop files
│   └── fonts/                          # User fonts
└── state/                              # XDG state

~/.var/                                 # Flatpak user data
└── app/
    ├── org.mozilla.firefox/
    ├── com.discordapp.Discord/
    └── ...

~/.ssh/                                 # SSH configuration
├── config                              # SSH host configs
├── known_hosts                         # Host fingerprints
└── authorized_keys                     # Allowed keys

~/.gnupg/                               # GPG keys
├── pubring.kbx                         # Public keyring
└── private-keys-v1.d/                  # Private keys
```

### Dotfile Management Strategy

**Option A: Git bare repo (recommended)**
```bash
# Initialize
git init --bare ~/.dotfiles.git
alias dotfiles='git --git-dir=$HOME/.dotfiles.git --work-tree=$HOME'
dotfiles config status.showUntrackedFiles no

# Usage
dotfiles add ~/.config/fish/config.fish
dotfiles commit -m "Add fish config"
dotfiles push origin main
```

**Option B: Symbolic links from repo**
```bash
# Clone dotfiles repo
git clone git@github.com:user/dotfiles.git ~/Projects/dotfiles

# Link configs
ln -s ~/Projects/dotfiles/fish ~/.config/fish
ln -s ~/Projects/dotfiles/nvim ~/.config/nvim
```

### NixOS Persistence Configuration

```nix
# configuration.nix
environment.persistence."/persist".users.user = {
  directories = [
    ".config"                           # App configs
    ".local"                            # Local data + scripts
    ".cache"                            # Caches (optional)
    ".ssh"                              # SSH keys
    ".gnupg"                            # GPG keys
    ".var"                              # Flatpak data
    "Documents"
    "Downloads"
    "Projects"
  ];
  files = [
    ".bash_history"
    ".zsh_history"
    ".local/share/fish/fish_history"
    "vault.tomb"                        # Encrypted vault
  ];
};
```

---

## 3. Mounts

### Mount Points

```
~/                                      # Home directory
├── mnt_git/                            # Git repositories
│   ├── unix/                           # This repo
│   ├── cloud/                          # Cloud infrastructure
│   ├── front-Github_io/                # Frontend projects
│   └── tools/                          # Shared tools
│
├── mnt_cloud/                          # Cloud storage
│   ├── gdrive_personal/                # Google Drive (personal)
│   ├── gdrive_work/                    # Google Drive (work)
│   └── onedrive/                       # OneDrive
│
├── mnt_sync/                           # Syncthing folders
│   ├── notes/                          # Obsidian vault
│   ├── photos/                         # Photo sync
│   └── documents/                      # Shared documents
│
└── mnt_remote/                         # Remote servers
    ├── oci_micro_1/                    # Oracle Cloud VM 1
    ├── oci_flex_1/                     # Oracle Cloud Flex
    └── gcp_micro_1/                    # Google Cloud VM
```

### Mount Configuration (b_mnt/mount.json)

```json
{
  "mounts": [
    {
      "name": "gdrive_personal",
      "type": "rclone",
      "remote": "gdrive_dnm:",
      "mountpoint": "~/mnt_cloud/gdrive_personal",
      "options": ["--vfs-cache-mode=writes"]
    },
    {
      "name": "oci_micro_1",
      "type": "sshfs",
      "remote": "ubuntu@130.110.251.193:/home/ubuntu",
      "mountpoint": "~/mnt_remote/oci_micro_1",
      "options": ["-o", "IdentityFile=~/.ssh/id_rsa"]
    },
    {
      "name": "notes",
      "type": "syncthing",
      "folder_id": "notes-sync",
      "mountpoint": "~/mnt_sync/notes"
    }
  ]
}
```

### Mount Script (b_mnt/mount.sh)

```bash
#!/bin/bash
# Mount all cloud and remote filesystems

case "$1" in
  start)
    # Cloud drives
    rclone mount gdrive_dnm: ~/mnt_cloud/gdrive_personal \
      --vfs-cache-mode writes --daemon

    # Remote servers
    sshfs ubuntu@130.110.251.193:/home/ubuntu ~/mnt_remote/oci_micro_1 \
      -o IdentityFile=~/.ssh/id_rsa
    ;;

  stop)
    fusermount -u ~/mnt_cloud/gdrive_personal
    fusermount -u ~/mnt_remote/oci_micro_1
    ;;

  status)
    mount | grep -E "rclone|sshfs|fuse"
    ;;
esac
```

### Systemd User Service (auto-mount)

```ini
# ~/.config/systemd/user/mount-clouds.service
[Unit]
Description=Mount cloud storage
After=network-online.target

[Service]
Type=oneshot
ExecStart=/home/user/mnt_git/unix/b_mnt/mount.sh start
ExecStop=/home/user/mnt_git/unix/b_mnt/mount.sh stop
RemainAfterExit=yes

[Install]
WantedBy=default.target
```

---

## 4. Vault

### Vault Structure (when open)

```
~/vault/                                # Mount point (tomb open)
├── keys/                               # Cryptographic keys
│   ├── ssh/                            # SSH keys
│   │   ├── id_ed25519                  # Primary SSH key
│   │   ├── id_ed25519.pub
│   │   ├── github                      # GitHub-specific
│   │   └── servers/                    # Per-server keys
│   ├── gpg/                            # GPG keys backup
│   │   └── secret-keys.asc
│   └── api/                            # API tokens
│       ├── cloudflare.key
│       ├── github.token
│       ├── oci.key
│       └── gcloud.json
│
├── secrets/                            # Passwords and 2FA
│   ├── passwords.kdbx                  # KeePass database
│   ├── 2fa-recovery/                   # TOTP recovery codes
│   │   ├── github.txt
│   │   ├── google.txt
│   │   └── ...
│   └── master.key.age                  # Master password (encrypted)
│
└── documents/                          # Sensitive documents
    ├── identity/                       # ID scans
    │   ├── passport.pdf
    │   └── drivers-license.pdf
    └── financial/                      # Financial docs
        ├── tax-2025.pdf
        └── bank-statements/
```

### Tomb Commands

```bash
# Create vault (one-time setup)
tomb dig -s 1024 ~/vault.tomb          # Create 1GB tomb file
tomb forge ~/vault.tomb.key            # Create key (on USB)
tomb lock ~/vault.tomb -k ~/vault.tomb.key

# Daily usage
tomb open ~/vault.tomb -k /usb-key/.vault/vault.key
# ... work with vault ...
tomb close vault

# Status
tomb list                              # Show open tombs

# Resize vault
tomb resize ~/vault.tomb -s 2048       # Grow to 2GB
```

### Vault Unlock Script

```bash
#!/bin/bash
# ~/bin/vault-open

TOMB_FILE="$HOME/vault.tomb"
KEY_LOCATIONS=(
  "/media/VTOYEFI/.vault/vault.key"    # USB key
  "/tmp/vault.key"                      # Temporary (for clipboard paste)
)

for KEY in "${KEY_LOCATIONS[@]}"; do
  if [[ -f "$KEY" ]]; then
    echo "Found key at $KEY"
    tomb open "$TOMB_FILE" -k "$KEY"
    exit 0
  fi
done

echo "No key found. Enter key manually:"
tomb open "$TOMB_FILE"
```

### SSH Agent Integration

```bash
# When vault opens, add SSH keys to agent
tomb open ~/vault.tomb -k $KEY -- ssh-add ~/vault/keys/ssh/id_ed25519

# Or via tomb hooks
# ~/vault/.last (executed after mount)
#!/bin/bash
ssh-add ~/vault/keys/ssh/id_ed25519
ssh-add ~/vault/keys/ssh/github
```

### NixOS Configuration for Vault

```nix
# configuration.nix
environment.systemPackages = with pkgs; [
  tomb                                  # LUKS file containers
  pinentry-curses                       # For passphrase entry
  age                                   # Modern encryption
];

# Persist the tomb file (but NOT the key!)
environment.persistence."/persist".users.user.files = [
  "vault.tomb"
];

# SSH agent for key management
programs.ssh.startAgent = true;
```

---

## Daily Workflow

### Morning Startup

```bash
# 1. Boot NixOS (LUKS unlocked via USB key)

# 2. Login to KDE Plasma

# 3. Auto-mounted at login:
#    - @user/home → /home/user
#    - @shared/containers → /var/lib/containers

# 4. Mount cloud storage (if not auto)
~/mnt_git/unix/b_mnt/mount.sh start

# 5. Open vault when needed
tomb open ~/vault.tomb -k /usb-key/.vault/vault.key

# 6. SSH keys available
ssh-add -l
```

### Development Session

```bash
# Enter development container
distrobox enter arch-dev

# Work on project
cd ~/mnt_git/cloud
vim configuration.nix

# Exit container
exit

# Commit (from host, using host git)
cd ~/mnt_git/cloud
git add . && git commit -m "Update config"
```

### End of Day

```bash
# Close vault
tomb close vault

# Unmount cloud storage (optional)
~/mnt_git/unix/b_mnt/mount.sh stop

# Commit any changes
cd ~/mnt_git/unix && git status

# Shutdown
# (tmpfs root wiped, persistent data in BTRFS subvolumes)
```

---

## Backup Strategy

| Data | Location | Backup Target | Frequency |
|------|----------|---------------|-----------|
| Configs | ~/.config | Git repo | On change |
| Projects | ~/Projects | Git remotes | On commit |
| Vault | ~/vault.tomb | Encrypted cloud | Weekly |
| Documents | ~/Documents | Syncthing + cloud | Real-time |
| Photos | ~/mnt_sync/photos | Cloud + NAS | Real-time |

### Vault Backup Script

```bash
#!/bin/bash
# Backup vault to encrypted cloud storage

VAULT="$HOME/vault.tomb"
BACKUP_DIR="gdrive_personal:backups/vault"
DATE=$(date +%Y%m%d)

# Verify vault is closed
if tomb list | grep -q vault; then
  echo "ERROR: Close vault before backup"
  exit 1
fi

# Upload encrypted tomb file
rclone copy "$VAULT" "$BACKUP_DIR" --progress
rclone copy "$VAULT" "$BACKUP_DIR/archive/$DATE.tomb" --progress

echo "Vault backed up to $BACKUP_DIR"
```
