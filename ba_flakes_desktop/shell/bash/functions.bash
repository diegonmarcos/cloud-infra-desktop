#!/bin/bash
# =============================================================================
# BASH FUNCTIONS - Comprehensive function definitions
# Source: shell/bash/functions.bash
# =============================================================================

# =============================================================================
# DIRECTORY OPERATIONS
# =============================================================================

# Create directory and cd into it
mkcd() {
    mkdir -p "$1" && cd "$1"
}

# Alias for mkcd
mkd() {
    mkdir -p "$@" && cd "${@: -1}"
}

# =============================================================================
# FILE OPERATIONS
# =============================================================================

# Extract any archive format
extract() {
    if [ -f "$1" ]; then
        case "$1" in
            *.tar.bz2)   tar xjf "$1"     ;;
            *.tar.gz)    tar xzf "$1"     ;;
            *.tar.xz)    tar xf "$1"      ;;
            *.tar.zst)   unzstd "$1"      ;;
            *.bz2)       bunzip2 "$1"     ;;
            *.rar)       unrar x "$1"     ;;
            *.gz)        gunzip "$1"      ;;
            *.tar)       tar xf "$1"      ;;
            *.tbz2)      tar xjf "$1"     ;;
            *.tgz)       tar xzf "$1"     ;;
            *.zip)       unzip "$1"       ;;
            *.Z)         uncompress "$1"  ;;
            *.7z)        7z x "$1"        ;;
            *.deb)       ar x "$1"        ;;
            *)           echo "'$1' cannot be extracted via extract()" ;;
        esac
    else
        echo "'$1' is not a valid file"
    fi
}

# Quick find by name
qfind() {
    find . -name "*$1*"
}

# Backup file with timestamp
backup() {
    if [ -f "$1" ]; then
        local timestamp=$(date +%Y%m%d_%H%M%S)
        cp "$1" "$1.backup.$timestamp"
        echo "Backup created: $1.backup.$timestamp"
    else
        echo "File not found: $1"
    fi
}

# =============================================================================
# GIT HELPERS
# =============================================================================

# Get current git branch
git_current_branch() {
    git branch 2>/dev/null | sed -n '/\* /s///p'
}

# Quick git add all + commit with message
gcam() {
    git add --all && git commit -m "$1"
}

# Quick git push to current branch
gpsh() {
    git push origin $(git_current_branch)
}

# =============================================================================
# SYSTEM MONITORING
# =============================================================================

# CPU capacity/frequency check
cpucap() {
    for i in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        if [ -d "$i" ]; then
            cur=$(cat "$i/scaling_cur_freq" 2>/dev/null)
            max=$(cat "$i/scaling_max_freq" 2>/dev/null)
            if [ -n "$cur" ] && [ -n "$max" ]; then
                core=$(basename "$(dirname "$i")")
                printf "%s: %4d MHz / %4d MHz = %3d%%\n" "$core" $((cur/1000)) $((max/1000)) $((cur*100/max))
            fi
        fi
    done
}

# =============================================================================
# POETRY/PYTHON HELPERS
# =============================================================================

# Poetry package installer and runner with sudo support
pyp() {
    if [[ $# -lt 1 ]]; then
        echo "Error: Need at least one argument: [Package_Name] or [sudo Package_Name]."
        return 1
    fi

    local is_sudo_mode=false
    local target_package=""
    local extra_args=()

    if [[ "$1" == "sudo" ]]; then
        if [[ $# -lt 2 ]]; then
            echo "Error: 'pyp sudo' requires a package name: pyp sudo [package]."
            return 1
        fi
        is_sudo_mode=true
        target_package="$2"
        extra_args=("${@:3}")
    else
        target_package="$1"
        extra_args=("${@:2}")
    fi

    cd ~/sys/poetry_venv_1 || { echo "Error: Project directory not found."; return 1; }

    echo "Installing package: $target_package..."
    poetry add "$target_package"

    echo "Running command..."

    if [[ "$is_sudo_mode" == "true" ]]; then
        local abs_path=$(poetry run which "$target_package" 2>/dev/null)
        if [[ -z "$abs_path" ]]; then
            echo "Error: Could not find executable '$target_package' in Venv."
            return 1
        fi
        local args_string="${extra_args[*]}"
        local command_string="sudo \"$abs_path\" $args_string"
        echo "Executing with SUDO path fix: sh -c '$command_string'"
        poetry run sh -c "$command_string"
    else
        poetry run "$target_package" "${extra_args[@]}"
    fi
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Show all defined aliases (for welcome screen)
show_aliases() {
    echo -e "\n\033[1;34m=== DEFINED ALIASES ===\033[0m"
    alias | sed 's/^alias /  /' | sort
}

# Show all defined functions (for welcome screen)
show_functions() {
    echo -e "\n\033[1;34m=== DEFINED FUNCTIONS ===\033[0m"
    echo "  mkcd, mkd      - Create directory and cd into it"
    echo "  extract        - Extract any archive format"
    echo "  qfind          - Quick find by filename"
    echo "  backup         - Backup file with timestamp"
    echo "  gcam           - Git add all + commit"
    echo "  gpsh           - Git push to current branch"
    echo "  cpucap         - Show CPU frequency per core"
    echo "  pyp            - Poetry package runner"
    echo "  show_aliases   - List all aliases"
    echo "  show_functions - List all functions"
}

# Help command for shell features
myhelp() {
    echo -e "\n\033[1;32m##########################"
    echo -e "####### SHELL HELP #######"
    echo -e "##########################\033[0m\n"
    show_aliases
    show_functions
    echo ""
}
