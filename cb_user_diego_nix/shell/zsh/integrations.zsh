#!/bin/zsh
# =============================================================================
# ZSH INTEGRATIONS - External tool integrations
# Source: shell/zsh/integrations.zsh
# =============================================================================

# =============================================================================
# POWERLEVEL10K PROMPT (ZSH specific)
# =============================================================================
# Enable instant prompt (must be near top of zshrc)
typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet

if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
    source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Load p10k config if it exists
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

# =============================================================================
# OH-MY-ZSH
# =============================================================================
export ZSH="$HOME/.oh-my-zsh"

if [[ -d "$ZSH" ]]; then
    ZSH_THEME="powerlevel10k/powerlevel10k"
    plugins=(git wakatime)
    source $ZSH/oh-my-zsh.sh
fi

# =============================================================================
# WAKATIME (if not using oh-my-zsh plugin)
# =============================================================================
# Fallback if oh-my-zsh not available
if [[ ! -d "$ZSH" ]]; then
    if [[ -f "$HOME/.wakatime/wakatime-cli" ]] || command -v wakatime &>/dev/null; then
        # Manual wakatime integration
        _wakatime_heartbeat() {
            local project="Terminal"
            if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
                project=$(basename "$(git rev-parse --show-toplevel)")
            fi
            (wakatime --write --plugin "zsh-wakatime/1.0.0" --entity-type app --project "$project" --entity "${1%% *}" &>/dev/null &)
        }
        preexec_functions+=(_wakatime_heartbeat)
    fi
fi

# =============================================================================
# NVM (Node Version Manager)
# =============================================================================
export NVM_DIR="$HOME/.nvm"
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    \. "$NVM_DIR/nvm.sh"
fi
if [[ -s "$NVM_DIR/bash_completion" ]]; then
    \. "$NVM_DIR/bash_completion"
fi

# =============================================================================
# CARGO/RUST
# =============================================================================
if [[ -f "$HOME/.cargo/env" ]]; then
    . "$HOME/.cargo/env"
fi

# =============================================================================
# FZF (Fuzzy finder)
# =============================================================================
if [[ -f "$HOME/.fzf.zsh" ]]; then
    source "$HOME/.fzf.zsh"
fi

# =============================================================================
# DIRENV (Directory-specific environments)
# =============================================================================
if command -v direnv &>/dev/null; then
    eval "$(direnv hook zsh)"
fi

# =============================================================================
# ZOXIDE (Smart cd)
# =============================================================================
if command -v zoxide &>/dev/null; then
    eval "$(zoxide init zsh)"
fi
