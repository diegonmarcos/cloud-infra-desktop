# =============================================================================
# FISH CONFIG - Main Fish shell configuration
# Source: shell/fish/config.fish
# =============================================================================
# Fish automatically sources files in conf.d/ and functions/
# This file is for any additional configuration not in those directories
# =============================================================================

# =============================================================================
# FISH OPTIONS
# =============================================================================

# Disable greeting
set -g fish_greeting ""

# Vi mode (optional - uncomment to enable)
# fish_vi_key_bindings

# =============================================================================
# CONF.D AUTO-SOURCING
# =============================================================================
# Fish automatically sources all .fish files in:
#   ~/.config/fish/conf.d/
#
# Our modular files (loaded in order by filename prefix):
#   00-aliases.fish      - All aliases
#   10-integrations.fish - External tools (starship, nvm, cargo, etc.)
#   99-startup.fish      - Welcome screen and auto-services
#
# Keep existing files:
#   chrome-dev.fish      - Browser dev aliases
#   nix.fish             - NixOS integration
#   rustup.fish          - Rust toolchain
#   wakatime.fish        - WakaTime integration

# =============================================================================
# FUNCTIONS AUTO-LOADING
# =============================================================================
# Fish automatically loads functions from:
#   ~/.config/fish/functions/
#
# Our function files:
#   mkcd.fish, mkd.fish, extract.fish, qfind.fish, backup.fish
#   git_current_branch.fish, gcam.fish, gpsh.fish
#   cpucap.fish, path.fish, duh.fish, hg.fish, localip.fish
#   show_aliases.fish, show_functions.fish, myhelp.fish
#   ccusage-models.fish, pyp.fish, fisher.fish

# =============================================================================
# LOCAL OVERRIDES
# =============================================================================
# Source local customizations if they exist (not tracked in git)
if test -f ~/.config/fish/config.fish.local
    source ~/.config/fish/config.fish.local
end
