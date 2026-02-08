# =============================================================================
# FISH INTEGRATIONS - External tool integrations
# Source: shell/fish/conf.d/10-integrations.fish
# =============================================================================

# =============================================================================
# ENVIRONMENT VARIABLES
# =============================================================================
set -gx EDITOR nano
set -gx VISUAL $EDITOR
set -gx PAGER less
set -gx LANG en_US.UTF-8
set -gx DBX_CONTAINER_MANAGER docker
set -g path_to_my_git "/home/diego/Documents/Git/"

# =============================================================================
# PATH
# =============================================================================
fish_add_path -g $HOME/.local/bin

# =============================================================================
# STARSHIP PROMPT
# =============================================================================
if command -v starship &>/dev/null
    starship init fish | source
end

# =============================================================================
# NVM (Node Version Manager) via bass or nvm.fish
# =============================================================================
set -gx NVM_DIR $HOME/.nvm

# If using bass (install via: omf install bass)
# function nvm
#     bass source $NVM_DIR/nvm.sh --no-use ';' nvm $argv
# end

# If using nvm.fish plugin, it handles this automatically

# =============================================================================
# CARGO/RUST
# =============================================================================
if test -f $HOME/.cargo/env
    # Fish can't source bash files directly, so we set the path
    fish_add_path -g $HOME/.cargo/bin
end

# =============================================================================
# FZF (Fuzzy finder)
# =============================================================================
if command -v fzf &>/dev/null
    # fzf key bindings (if installed via package manager)
    if test -f /usr/share/fzf/key-bindings.fish
        source /usr/share/fzf/key-bindings.fish
    end
end

# =============================================================================
# DIRENV (Directory-specific environments)
# =============================================================================
if command -v direnv &>/dev/null
    direnv hook fish | source
end

# =============================================================================
# ZOXIDE (Smart cd)
# =============================================================================
if command -v zoxide &>/dev/null
    zoxide init fish | source
end
