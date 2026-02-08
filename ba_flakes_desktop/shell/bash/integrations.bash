#!/bin/bash
# =============================================================================
# BASH INTEGRATIONS - External tool integrations
# Source: shell/bash/integrations.bash
# =============================================================================

# =============================================================================
# STARSHIP PROMPT
# =============================================================================
if command -v starship &>/dev/null; then
    eval "$(starship init bash)"
fi

# =============================================================================
# WAKATIME (Coding time tracker)
# =============================================================================
# WakaTime for Bash - tracks commands for productivity metrics
if [ -f "$HOME/.bash-wakatime/bash-wakatime.sh" ]; then
    source "$HOME/.bash-wakatime/bash-wakatime.sh"
elif [ -f "$HOME/.wakatime/bash-wakatime.sh" ]; then
    source "$HOME/.wakatime/bash-wakatime.sh"
fi

# =============================================================================
# NVM (Node Version Manager)
# =============================================================================
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
    \. "$NVM_DIR/nvm.sh"
fi
if [ -s "$NVM_DIR/bash_completion" ]; then
    \. "$NVM_DIR/bash_completion"
fi

# =============================================================================
# CARGO/RUST
# =============================================================================
if [ -f "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi

# =============================================================================
# FZF (Fuzzy finder)
# =============================================================================
if [ -f "$HOME/.fzf.bash" ]; then
    source "$HOME/.fzf.bash"
fi

# =============================================================================
# DIRENV (Directory-specific environments)
# =============================================================================
if command -v direnv &>/dev/null; then
    eval "$(direnv hook bash)"
fi

# =============================================================================
# ZOXIDE (Smart cd)
# =============================================================================
if command -v zoxide &>/dev/null; then
    eval "$(zoxide init bash)"
fi
