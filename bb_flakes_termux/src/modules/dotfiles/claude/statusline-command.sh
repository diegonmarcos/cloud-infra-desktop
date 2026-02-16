#!/usr/bin/env bash
# Status line command for Claude Code (Termux)
# Shows: Git branch | WireGuard status | Current directory
# Source: unix/bb_flakes_termux/src/modules/dotfiles/claude/statusline-command.sh

set -euo pipefail

# Git branch
if git rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || echo "detached")
    GIT_INFO=" \033[36m($BRANCH)\033[0m"
else
    GIT_INFO=""
fi

# WireGuard status
if [ -f /proc/sys/net/ipv4/conf/wg0/forwarding ] 2>/dev/null; then
    WG_IP=$(ip addr show wg0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "down")
    if [ "$WG_IP" = "down" ]; then
        WG_INFO=" \033[31m[WG:down]\033[0m"
    else
        WG_INFO=" \033[32m[WG:$WG_IP]\033[0m"
    fi
else
    WG_INFO=" \033[31m[WG:off]\033[0m"
fi

# Current directory (shortened)
DIR=$(pwd | sed "s|$HOME|~|")

# Output
echo -e "\033[1;34m$DIR\033[0m$GIT_INFO$WG_INFO"
