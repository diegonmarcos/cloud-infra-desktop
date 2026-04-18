# NODE_PATH for shared ~/.node_modules (ESM doesn't read NODE_PATH, but CJS + tsx do)
set -gx NODE_PATH "$HOME/.node_modules/node_modules"

# Starship prompt
if command -v starship &>/dev/null
  starship init fish | source
end

# Zoxide
if command -v zoxide &>/dev/null
  zoxide init fish | source
end

# Atuin (shell history) — keep arrow-up for classic per-command recall, Ctrl+R for atuin
if command -v atuin &>/dev/null
  atuin init fish --disable-up-arrow | source
end

# FZF
if command -v fzf &>/dev/null
  fzf --fish | source
end

# Direnv
if command -v direnv &>/dev/null
  direnv hook fish | source
end

# API keys from vault (read at shell init, not baked into Nix store)
if test -f ~/git/vault/A0_keys/providers/anthropic/api-key_opaque
  set -gx ANTHROPIC_API_KEY (cat ~/git/vault/A0_keys/providers/anthropic/api-key_opaque)
end

# Vi mode
fish_vi_key_bindings

# Keybinding: Ctrl+P to search available commands with fzf
bind \cp '__fzf_search_commands'
bind -M insert \cp '__fzf_search_commands'

# NVM via bass (if available)
# set -gx NVM_DIR $HOME/.nvm

# Ensure user PATH entries are set even when __HM_SESS_VARS_SOURCED is
# inherited from a parent process (e.g. Plasma → Konsole).
# fish_add_path is idempotent: no duplicates added.
if test -d /mnt/shared/tools/scripts
  fish_add_path /mnt/shared/tools/scripts
end
for dir in /mnt/shared/tools/devops/bin /mnt/shared/tools/data/bin /mnt/shared/tools/dev/bin /mnt/shared/tools/base/bin
  if test -d $dir
    fish_add_path $dir
  end
end
if test -d $HOME/.npm-global/bin
  fish_add_path $HOME/.npm-global/bin
end
if test -d $HOME/.cargo/bin
  fish_add_path $HOME/.cargo/bin
end
if test -d $HOME/.local/bin
  fish_add_path $HOME/.local/bin
end
# nix-profile must come LAST so it has highest PATH priority
# (patchelf'd binaries like claude-code override unpatched npm/cargo copies)
if test -d $HOME/.nix-profile/bin
  fish_add_path $HOME/.nix-profile/bin
end

# Authelia OIDC credentials (vault paths)
set -gx AUTHELIA_OIDC_CREDENTIALS_DIR "$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/credentials"
set -gx AUTHELIA_OIDC_TOKENS_DIR "$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens"
set -gx AUTHELIA_OIDC_CLIENT_ID "claude-admin"
set -gx AUTHELIA_TOKEN_URL "https://auth.diegonmarcos.com/api/oidc/token"

# http-dev runs as systemd user service (not per-shell)
set -g __httpd_port 8000

# Local overrides
if test -f ~/.config/fish/config.local.fish
  source ~/.config/fish/config.local.fish
end
