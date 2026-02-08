{ config, pkgs, lib, ... }:

# =============================================================================
# Shell Configuration for Diego
# =============================================================================
# Usage: Import this in your main home.nix
#   imports = [ ./shell/home.nix ];
#
# Structure:
#   shell/
#   ├── bash/
#   │   ├── bashrc           # Main config
#   │   ├── aliases.bash     # All aliases
#   │   ├── functions.bash   # All functions
#   │   ├── integrations.bash # External tools
#   │   └── startup.bash     # Welcome screen
#   ├── zsh/
#   │   ├── zshrc            # Main config
#   │   ├── aliases.zsh      # All aliases
#   │   ├── functions.zsh    # All functions
#   │   ├── functions-c-dev.zsh # C development
#   │   ├── integrations.zsh # External tools
#   │   ├── startup.zsh      # Welcome screen
#   │   ├── p10k.zsh         # Powerlevel10k config
#   │   └── zprofile         # Login profile
#   └── fish/
#       ├── config.fish      # Main config
#       ├── conf.d/          # Auto-sourced configs
#       │   ├── 00-aliases.fish
#       │   ├── 10-integrations.fish
#       │   ├── 99-startup.fish
#       │   └── wakatime.fish
#       └── functions/       # Auto-loaded functions
# =============================================================================

let
  shellConfigDir = ./.;
in
{
  # ===========================================================================
  # PACKAGES - Shell tools and dependencies
  # ===========================================================================
  home.packages = with pkgs; [
    # Shell essentials
    zsh
    fish
    starship

    # Zsh enhancements
    oh-my-zsh
    zsh-powerlevel10k

    # Fish plugins manager
    fishPlugins.fisher

    # CLI tools used in configs
    ripgrep
    fd
    bat
    eza
    fzf
    jq
    zoxide

    # Dev tools
    python3
    poetry

    # System tools
    lsof
    unzip
    p7zip
    unrar
  ];

  # ===========================================================================
  # BASH Configuration
  # ===========================================================================
  programs.bash = {
    enable = true;
    bashrcExtra = builtins.readFile ./bash/bashrc;
    profileExtra = lib.optionalString (builtins.pathExists ./profile)
      (builtins.readFile ./profile);
  };

  # ===========================================================================
  # ZSH Configuration
  # ===========================================================================
  programs.zsh = {
    enable = true;

    # Let our modular zshrc handle oh-my-zsh and plugins
    initExtra = builtins.readFile ./zsh/zshrc;

    profileExtra = lib.optionalString (builtins.pathExists ./zsh/zprofile)
      (builtins.readFile ./zsh/zprofile);
  };

  # ===========================================================================
  # FISH Configuration
  # ===========================================================================
  programs.fish = {
    enable = true;

    # Main config
    interactiveShellInit = builtins.readFile ./fish/config.fish;

    # Plugins
    plugins = [
      # Add plugins here if needed
      # { name = "z"; src = pkgs.fishPlugins.z.src; }
    ];
  };

  # ===========================================================================
  # STARSHIP Prompt
  # ===========================================================================
  programs.starship = {
    enable = true;
    enableBashIntegration = false;  # Handled in integrations.bash
    enableZshIntegration = false;   # Using p10k for zsh
    enableFishIntegration = false;  # Handled in integrations.fish
  };

  # ===========================================================================
  # HOME FILES - Copy config files to appropriate locations
  # ===========================================================================
  home.file = {
    # --- BASH ---
    ".config/shell/bash/aliases.bash".source = ./bash/aliases.bash;
    ".config/shell/bash/functions.bash".source = ./bash/functions.bash;
    ".config/shell/bash/integrations.bash".source = ./bash/integrations.bash;
    ".config/shell/bash/startup.bash".source = ./bash/startup.bash;

    # --- ZSH ---
    ".config/shell/zsh/aliases.zsh".source = ./zsh/aliases.zsh;
    ".config/shell/zsh/functions.zsh".source = ./zsh/functions.zsh;
    ".config/shell/zsh/functions-c-dev.zsh".source = ./zsh/functions-c-dev.zsh;
    ".config/shell/zsh/integrations.zsh".source = ./zsh/integrations.zsh;
    ".config/shell/zsh/startup.zsh".source = ./zsh/startup.zsh;
    ".p10k.zsh" = lib.mkIf (builtins.pathExists ./zsh/p10k.zsh) {
      source = ./zsh/p10k.zsh;
    };

    # --- FISH ---
    ".config/fish/conf.d/00-aliases.fish".source = ./fish/conf.d/00-aliases.fish;
    ".config/fish/conf.d/10-integrations.fish".source = ./fish/conf.d/10-integrations.fish;
    ".config/fish/conf.d/99-startup.fish".source = ./fish/conf.d/99-startup.fish;

    # Keep existing fish conf.d files
    ".config/fish/conf.d/wakatime.fish" = lib.mkIf (builtins.pathExists ./fish/conf.d/wakatime.fish) {
      source = ./fish/conf.d/wakatime.fish;
    };
    ".config/fish/conf.d/nix.fish" = lib.mkIf (builtins.pathExists ./fish/conf.d/nix.fish) {
      source = ./fish/conf.d/nix.fish;
    };
    ".config/fish/conf.d/rustup.fish" = lib.mkIf (builtins.pathExists ./fish/conf.d/rustup.fish) {
      source = ./fish/conf.d/rustup.fish;
    };
    ".config/fish/conf.d/chrome-dev.fish" = lib.mkIf (builtins.pathExists ./fish/conf.d/chrome-dev.fish) {
      source = ./fish/conf.d/chrome-dev.fish;
    };

    # Fish functions directory
    ".config/fish/functions" = lib.mkIf (builtins.pathExists ./fish/functions) {
      source = ./fish/functions;
      recursive = true;
    };

    # Fish plugins list
    ".config/fish/fish_plugins" = lib.mkIf (builtins.pathExists ./fish/fish_plugins) {
      source = ./fish/fish_plugins;
    };
  };

  # ===========================================================================
  # ENVIRONMENT VARIABLES
  # ===========================================================================
  home.sessionVariables = {
    EDITOR = "nano";
    VISUAL = "nano";
    PAGER = "less";
    PATH = "$HOME/.local/bin:$PATH";
    DBX_CONTAINER_MANAGER = "docker";
  };
}
