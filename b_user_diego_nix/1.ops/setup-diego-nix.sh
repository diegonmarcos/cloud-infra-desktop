#!/usr/bin/env bash
# Setup diego_nix user with data from diego
# Run as: sudo ./setup-diego-nix.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)"
   exit 1
fi

DIEGO_HOME="/home/diego"
DIEGO_NIX_HOME="/home/diego_nix"

echo "=== Setting up diego_nix user ==="
echo ""

# 1. Create user if doesn't exist
if ! id diego_nix &>/dev/null; then
    echo "Creating diego_nix user..."
    # Create user without password prompt
    adduser --disabled-password --gecos "Diego Nix" diego_nix

    # Copy groups from diego
    echo "Copying groups from diego..."
    DIEGO_GROUPS=$(id -nG diego | tr ' ' '\n' | grep -v "^diego$" | tr '\n' ',' | sed 's/,$//')
    if [ -n "$DIEGO_GROUPS" ]; then
        usermod -aG "$DIEGO_GROUPS" diego_nix
        echo "Added diego_nix to groups: $DIEGO_GROUPS"
    fi
else
    echo "diego_nix user already exists"
    echo "Adding missing groups..."
    DIEGO_GROUPS=$(id -nG diego | tr ' ' '\n' | grep -v "^diego$" | tr '\n' ',' | sed 's/,$//')
    if [ -n "$DIEGO_GROUPS" ]; then
        usermod -aG "$DIEGO_GROUPS" diego_nix
        echo "Added diego_nix to groups: $DIEGO_GROUPS"
    fi
fi

echo ""
echo "=== Copying Essential Data from diego ==="

# 2. SSH keys (CRITICAL for git, servers)
if [ -d "$DIEGO_HOME/.ssh" ]; then
    echo "Copying SSH keys..."
    cp -r "$DIEGO_HOME/.ssh" "$DIEGO_NIX_HOME/"
    chown -R diego_nix:diego_nix "$DIEGO_NIX_HOME/.ssh"
    chmod 700 "$DIEGO_NIX_HOME/.ssh"
    chmod 600 "$DIEGO_NIX_HOME/.ssh/"*
fi

# 3. GPG keys (for commit signing, encryption)
if [ -d "$DIEGO_HOME/.gnupg" ]; then
    echo "Copying GPG keys..."
    cp -r "$DIEGO_HOME/.gnupg" "$DIEGO_NIX_HOME/"
    chown -R diego_nix:diego_nix "$DIEGO_NIX_HOME/.gnupg"
    chmod 700 "$DIEGO_NIX_HOME/.gnupg"
fi

# 4. Git repositories (preserve your work)
if [ -d "$DIEGO_HOME/Documents/Git" ]; then
    echo "Linking Git repositories (read-only access)..."
    mkdir -p "$DIEGO_NIX_HOME/Documents"
    # Create symlink to access diego's git repos
    ln -sf "$DIEGO_HOME/Documents/Git" "$DIEGO_NIX_HOME/Documents/Git-shared"
    # Create empty Git directory for new repos
    mkdir -p "$DIEGO_NIX_HOME/Documents/Git"
    chown -R diego_nix:diego_nix "$DIEGO_NIX_HOME/Documents"
fi

# 5. Projects/Work (optional - symlink for access)
if [ -d "$DIEGO_HOME/mnt_git" ]; then
    echo "Linking mnt_git (shared access)..."
    ln -sf "$DIEGO_HOME/mnt_git" "$DIEGO_NIX_HOME/mnt_git-shared"
fi

# 6. Credentials & Configs (safe to copy)
echo "Copying application credentials..."

# AWS credentials
if [ -d "$DIEGO_HOME/.aws" ]; then
    cp -r "$DIEGO_HOME/.aws" "$DIEGO_NIX_HOME/"
    chown -R diego_nix:diego_nix "$DIEGO_NIX_HOME/.aws"
fi

# GCloud credentials
if [ -d "$DIEGO_HOME/.config/gcloud" ]; then
    mkdir -p "$DIEGO_NIX_HOME/.config"
    cp -r "$DIEGO_HOME/.config/gcloud" "$DIEGO_NIX_HOME/.config/"
    chown -R diego_nix:diego_nix "$DIEGO_NIX_HOME/.config/gcloud"
fi

# Kube config
if [ -f "$DIEGO_HOME/.kube/config" ]; then
    mkdir -p "$DIEGO_NIX_HOME/.kube"
    cp "$DIEGO_HOME/.kube/config" "$DIEGO_NIX_HOME/.kube/"
    chown -R diego_nix:diego_nix "$DIEGO_NIX_HOME/.kube"
fi

# Docker/Podman configs
if [ -d "$DIEGO_HOME/.docker" ]; then
    cp -r "$DIEGO_HOME/.docker" "$DIEGO_NIX_HOME/"
    chown -R diego_nix:diego_nix "$DIEGO_NIX_HOME/.docker"
fi

# 7. Browser profiles (optional - can be large)
# Uncomment if you want to copy browser data
# if [ -d "$DIEGO_HOME/.mozilla" ]; then
#     echo "Copying Firefox profile..."
#     cp -r "$DIEGO_HOME/.mozilla" "$DIEGO_NIX_HOME/"
#     chown -R diego_nix:diego_nix "$DIEGO_NIX_HOME/.mozilla"
# fi

# 8. Create workspace directories
echo "Creating workspace directories..."
mkdir -p "$DIEGO_NIX_HOME"/{Downloads,Documents,Pictures,Videos,Music,Desktop}
chown -R diego_nix:diego_nix "$DIEGO_NIX_HOME"/{Downloads,Documents,Pictures,Videos,Music,Desktop}

# 9. Save current dotfiles as reference
echo "Backing up diego's current dotfiles for reference..."
mkdir -p "$DIEGO_NIX_HOME/.dotfiles-from-diego"
for file in .bashrc .zshrc .vimrc .gitconfig .tmux.conf; do
    if [ -f "$DIEGO_HOME/$file" ]; then
        cp "$DIEGO_HOME/$file" "$DIEGO_NIX_HOME/.dotfiles-from-diego/"
    fi
done
chown -R diego_nix:diego_nix "$DIEGO_NIX_HOME/.dotfiles-from-diego"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Data copied to diego_nix:"
echo "  ✓ SSH keys"
echo "  ✓ GPG keys"
echo "  ✓ Cloud credentials (AWS, GCloud, Kube)"
echo "  ✓ Docker configs"
echo "  → Git repos linked (read-only): ~/Documents/Git-shared"
echo "  → mnt_git linked (shared): ~/mnt_git-shared"
echo ""
echo "Next steps:"
echo "  1. Login as diego_nix:"
echo "     su - diego_nix"
echo ""
echo "  2. Install Home Manager:"
echo "     cd /home/diego/mnt_git/unix/a_kubuntu"
echo "     ./scripts/install.sh surface"
echo ""
echo "  3. Compare environments:"
echo "     Terminal 1: diego user (traditional)"
echo "     Terminal 2: diego_nix user (Nix-managed)"
