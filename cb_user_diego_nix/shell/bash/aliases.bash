#!/bin/bash
# =============================================================================
# BASH ALIASES - Comprehensive alias definitions
# Source: shell/bash/aliases.bash
# =============================================================================

# =============================================================================
# PYTHON
# =============================================================================
alias py='python3'
alias python='python3'
alias pip='pip3'
alias ppy='poetry run python3'

# =============================================================================
# DIRECTORY NAVIGATION
# =============================================================================
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'

# =============================================================================
# LIST DIRECTORY (ls variants)
# =============================================================================
alias ls='ls --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias lh='ls -lh'
alias lt='ls -ltr'

# =============================================================================
# GIT - Basic
# =============================================================================
alias gs='git status'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit'
alias gcm='git commit -m'
alias gp='git push'
alias gl='git log --oneline --graph --decorate'
alias gla='git log --oneline --graph --decorate --all'
alias gd='git diff'
alias gds='git diff --staged'
alias gco='git checkout'
alias gb='git branch'
alias gba='git branch -a'
alias gpl='git pull'
alias gcl='git clone'
alias gst='git stash'
alias gstp='git stash pop'

# GIT - Quick operations
alias push='git add . && git commit -m "update" && git push'

# =============================================================================
# GREP (with colors)
# =============================================================================
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# =============================================================================
# SAFETY (prompt before destructive operations)
# =============================================================================
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'

# =============================================================================
# SYSTEM INFORMATION
# =============================================================================
alias df='df -h'
alias du='du -h'
alias duh='du -h --max-depth=1 | sort -h'
alias free='free -h'
alias psg='ps aux | grep -v grep | grep -i -e VSZ -e'
alias mem='free -h && sync && echo 3 | sudo tee /proc/sys/vm/drop_caches && free -h'

# =============================================================================
# NETWORKING
# =============================================================================
alias ports='netstat -tulanp'
alias myip='curl -s ifconfig.me'
alias localip="ip addr show | grep 'inet ' | grep -v 127.0.0.1 | awk '{print \$2}'"
alias ping='ping -c 5'
alias fastping='ping -c 100 -i 0.2'

# =============================================================================
# DOCKER
# =============================================================================
alias dps='docker ps'
alias dpsa='docker ps -a'
alias dcu='docker-compose up'
alias dcd='docker-compose down'
alias dlog='docker logs --tail 100'
alias dex='docker exec -it'

# =============================================================================
# DEVELOPMENT
# =============================================================================
alias serve='python3 -m http.server'
alias jn='jupyter notebook'

# =============================================================================
# BROWSER (no CORS for local dev)
# =============================================================================
alias chrome_no_CORS='chromium --disable-web-security --user-data-dir=/tmp/chrome-nocors'
alias chromium_no_CORS='chromium --disable-web-security --user-data-dir=/tmp/chrome-nocors'
alias brave_no_CORS='brave --disable-web-security --user-data-dir=/tmp/brave-nocors'

# =============================================================================
# MISC UTILITIES
# =============================================================================
alias c='clear'
alias h='history'
alias hg='history | grep'
alias path='echo -e ${PATH//:/\\n}'
alias week='date +%V'
alias timer='echo "Timer started. Stop with Ctrl-D." && date && time cat && date'
alias reload='source ~/.bashrc'

# =============================================================================
# CONFIG EDITING
# =============================================================================
alias editbash='${EDITOR:-nano} ~/.bashrc'
alias editalias='${EDITOR:-nano} ~/.config/shell/aliases.bash'

# =============================================================================
# NIX MANAGEMENT
# =============================================================================
alias nix-gc='nix-env --delete-generations +3 && sudo nix-env --delete-generations +3 -p /nix/var/nix/profiles/system && sudo nix-collect-garbage -d'
alias nix-gc-check='command df -h /nix && echo "--- User generations:" && nix-env --list-generations | tail -5 && echo "--- System generations:" && sudo nix-env --list-generations -p /nix/var/nix/profiles/system | tail -5'

# =============================================================================
# CUSTOM TOOLS (Diego's)
# =============================================================================
alias gdrive='bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh'
alias gdrive_mount='bash /home/diego/Documents/Git/mylibs/mytools/0_unix/rclone_mount.sh b1'
alias gdrive_umount='fusermount -u /home/diego/Documents/Gdrive'
alias mem_recover='/home/diego/Documents/Git/mylibs/mytools/0_unix/kill_halt.sh'
alias mem_usage='/home/diego/Documents/Git/mylibs/mytools/0_unix/mem_usage.sh'
