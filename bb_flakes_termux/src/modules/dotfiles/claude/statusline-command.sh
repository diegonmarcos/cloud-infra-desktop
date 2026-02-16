#!/usr/bin/env bash
# Comprehensive status line for Claude Code (Termux)
# Shows: Model | Context | Session | Git | WireGuard | System | Directory
# Source: unix/bb_flakes_termux/src/modules/dotfiles/claude/statusline-command.sh

set -euo pipefail

# === Model Info ===
MODEL=$(jq -r '.model // "sonnet"' ~/.claude/settings.json 2>/dev/null || echo "sonnet")
case "$MODEL" in
    opus*) MODEL_DISPLAY="\033[35m󰛄 OPUS\033[0m" ;;
    sonnet*) MODEL_DISPLAY="\033[36m SONNET\033[0m" ;;
    haiku*) MODEL_DISPLAY="\033[32m HAIKU\033[0m" ;;
    *) MODEL_DISPLAY="\033[37m $MODEL\033[0m" ;;
esac

# === Context Window (from statusline input if available) ===
if [ -n "${CLAUDE_CONTEXT_USED:-}" ] && [ -n "${CLAUDE_CONTEXT_TOTAL:-}" ]; then
    PERCENT=$((CLAUDE_CONTEXT_USED * 100 / CLAUDE_CONTEXT_TOTAL))
    if [ $PERCENT -gt 80 ]; then
        CTX_COLOR="\033[31m" # Red
    elif [ $PERCENT -gt 60 ]; then
        CTX_COLOR="\033[33m" # Yellow
    else
        CTX_COLOR="\033[32m" # Green
    fi
    CONTEXT=" ${CTX_COLOR}${PERCENT}%\033[0m"
else
    CONTEXT=""
fi

# === Session Info ===
if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    SESSION_SHORT="${CLAUDE_SESSION_ID:0:8}"
    SESSION=" \033[90m[${SESSION_SHORT}]\033[0m"
else
    SESSION=""
fi

# === Git Branch ===
if git rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || echo "detached")
    GIT=" \033[36m($BRANCH)\033[0m"
else
    GIT=""
fi

# === WireGuard Status ===
if [ -f /proc/sys/net/ipv4/conf/wg0/forwarding ] 2>/dev/null; then
    WG_IP=$(ip addr show wg0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "down")
    if [ "$WG_IP" = "down" ]; then
        WG=" \033[31m󰖂 down\033[0m"
    else
        WG=" \033[32m󰖂 ${WG_IP}\033[0m"
    fi
else
    WG=" \033[31m󰖂 off\033[0m"
fi

# === System Load & Memory ===
LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "?")
MEM_TOTAL=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
if [ "$MEM_TOTAL" != "?" ] && [ "$MEM_AVAIL" != "?" ]; then
    MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
    MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    if [ $MEM_PERCENT -gt 80 ]; then
        MEM_COLOR="\033[31m"
    else
        MEM_COLOR="\033[37m"
    fi
    SYS=" \033[37m${LOAD}\033[0m ${MEM_COLOR}${MEM_USED}M\033[0m"
else
    SYS=" \033[37m${LOAD}\033[0m"
fi

# === Docker Status (if accessible) ===
if command -v docker &> /dev/null && docker info &> /dev/null; then
    RUNNING=$(docker ps -q 2>/dev/null | wc -l)
    if [ "$RUNNING" -gt 0 ]; then
        DOCKER=" \033[36m ${RUNNING}\033[0m"
    else
        DOCKER=" \033[90m 0\033[0m"
    fi
else
    DOCKER=""
fi

# === Current Directory ===
DIR=$(pwd | sed "s|$HOME|~|")

# === Output ===
echo -e "${MODEL_DISPLAY}${CONTEXT}${SESSION} \033[1;34m${DIR}\033[0m${GIT}${WG}${SYS}${DOCKER}"
