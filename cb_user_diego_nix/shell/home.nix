{ config, pkgs, lib, ... }:

# Shell Configuration for Diego
# Usage: Import this in your main home.nix
#   imports = [ ./shell/home.nix ];

let
  shellConfigDir = ./.; # Relative to this file
in
{
  # ============================================================================
  # PACKAGES - Shell tools and dependencies
  # ============================================================================
  home.packages = with pkgs; [
    # Shell essentials
    zsh
    fish
    starship

    # Oh-my-zsh and powerlevel10k (zsh)
    oh-my-zsh
    zsh-powerlevel10k

    # Fish plugins manager
    fishPlugins.fisher

    # CLI tools used in configs
    ripgrep
    fd
    bat
    eza          # modern ls
    fzf
    jq

    # Dev tools referenced in configs
    python3
    poetry

    # System tools
    lsof
    nettools     # netstat
    unzip
    p7zip
    unrar
  ];

  # ============================================================================
  # BASH Configuration
  # ============================================================================
  programs.bash = {
    enable = true;

    # Source the existing bashrc content
    bashrcExtra = builtins.readFile ./bash/bashrc;

    profileExtra = lib.optionalString (builtins.pathExists ./profile)
      (builtins.readFile ./profile);
  };

  # ============================================================================
  # ZSH Configuration
  # ============================================================================
  programs.zsh = {
    enable = true;

    # Oh-my-zsh
    oh-my-zsh = {
      enable = true;
      plugins = [ "git" "wakatime" ];
      theme = ""; # We use powerlevel10k instead
    };

    # Powerlevel10k
    plugins = [
      {
        name = "powerlevel10k";
        src = pkgs.zsh-powerlevel10k;
        file = "share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
      }
    ];

    # Source the existing zshrc (after oh-my-zsh setup)
    initExtra = ''
      # Powerlevel10k instant prompt
      typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet
      if [[ -r "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh" ]]; then
        source "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh"
      fi

      # Load p10k config
      [[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

      # Load custom config
      ${builtins.readFile ./zsh/zshrc}
    '';

    # Profile
    profileExtra = lib.optionalString (builtins.pathExists ./zsh/zprofile)
      (builtins.readFile ./zsh/zprofile);
  };

  # ============================================================================
  # FISH Configuration
  # ============================================================================
  programs.fish = {
    enable = true;

    # Starship prompt
    interactiveShellInit = ''
      # Starship prompt
      starship init fish | source

      # Load main config
      ${builtins.readFile ./fish/config.fish}
    '';

    # Plugins via fisher
    plugins = [
      # Add plugins here if needed
      # { name = "z"; src = pkgs.fishPlugins.z.src; }
    ];
  };

  # ============================================================================
  # STARSHIP Prompt (shared across shells)
  # ============================================================================
  programs.starship = {
    enable = true;
    enableBashIntegration = false;  # We handle this in bashrc
    enableZshIntegration = false;   # We use p10k for zsh
    enableFishIntegration = false;  # We handle this in config.fish
  };

  # ============================================================================
  # HOME FILES - Copy additional config files
  # ============================================================================
  home.file = {
    # Powerlevel10k config
    ".p10k.zsh" = lib.mkIf (builtins.pathExists ./zsh/p10k.zsh) {
      source = ./zsh/p10k.zsh;
    };

    # Fish functions
    ".config/fish/functions" = lib.mkIf (builtins.pathExists ./fish/functions) {
      source = ./fish/functions;
      recursive = true;
    };

    # Fish conf.d
    ".config/fish/conf.d" = lib.mkIf (builtins.pathExists ./fish/conf.d) {
      source = ./fish/conf.d;
      recursive = true;
    };

    # Fish plugins list
    ".config/fish/fish_plugins" = lib.mkIf (builtins.pathExists ./fish/fish_plugins) {
      source = ./fish/fish_plugins;
    };
  };

  # ============================================================================
  # ENVIRONMENT VARIABLES
  # ============================================================================
  home.sessionVariables = {
    EDITOR = "nano";
    PATH = "$HOME/.local/bin:$PATH";
    DBX_CONTAINER_MANAGER = "docker";
  };
}
