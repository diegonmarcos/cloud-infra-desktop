# Zsh shell configuration
{ config, pkgs, lib, ... }:

{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    history = {
      size = 10000;
      save = 10000;
      path = "${config.xdg.dataHome}/zsh/history";
      ignoreDups = true;
      ignoreSpace = true;
      extended = true;
      share = true;
    };

    shellAliases = {
      # Modern CLI replacements
      ls = "eza --color=auto --icons";
      ll = "eza -alF --icons";
      la = "eza -A --icons";
      lt = "eza --tree --level=2 --icons";
      cat = "bat --paging=never";
      grep = "rg";
      find = "fd";

      # Navigation
      ".." = "cd ..";
      "..." = "cd ../..";
      "...." = "cd ../../..";

      # Git shortcuts
      gs = "git status -sb";
      ga = "git add";
      gc = "git commit";
      gp = "git push";
      gl = "git log --oneline -20";
      gd = "git diff";

      # Podman
      docker = "podman";

      # Misc
      cls = "clear";
      path = "echo $PATH | tr ':' '\\n'";
    };

    initExtra = ''
      # Vi mode
      bindkey -v
      export KEYTIMEOUT=1

      # Better history search
      bindkey '^R' history-incremental-search-backward
      bindkey '^P' up-line-or-search
      bindkey '^N' down-line-or-search

      # Edit command in editor
      autoload -Uz edit-command-line
      zle -N edit-command-line
      bindkey '^X^E' edit-command-line

      # Starship prompt
      if command -v starship &>/dev/null; then
        eval "$(starship init zsh)"
      fi

      # Zoxide
      if command -v zoxide &>/dev/null; then
        eval "$(zoxide init zsh)"
      fi

      # FZF
      if command -v fzf &>/dev/null; then
        source <(fzf --zsh)
      fi

      # Functions
      mkcd() { mkdir -p "$1" && cd "$1"; }

      # Local overrides
      [[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
    '';
  };
}
