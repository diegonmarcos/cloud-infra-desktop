{ config, pkgs, lib, ... }:

# SIMPLE Shell Configuration - Just copies files directly
# Use this if the main home.nix has escaping issues with ASCII art
#
# Usage: Import this in your main home.nix
#   imports = [ ./shell/home-simple.nix ];

{
  # ============================================================================
  # PACKAGES
  # ============================================================================
  home.packages = with pkgs; [
    zsh
    fish
    starship
    oh-my-zsh
    zsh-powerlevel10k
    fishPlugins.fisher
  ];

  # ============================================================================
  # Enable shells (minimal config - files are copied directly)
  # ============================================================================
  programs.bash.enable = true;
  programs.zsh.enable = true;
  programs.fish.enable = true;

  # ============================================================================
  # HOME FILES - Copy all config files directly
  # ============================================================================
  home.file = {
    # Bash
    ".bashrc".source = ./bash/bashrc;

    # Zsh
    ".zshrc".source = ./zsh/zshrc;
    ".zprofile".source = ./zsh/zprofile;
    ".p10k.zsh".source = ./zsh/p10k.zsh;

    # Fish
    ".config/fish/config.fish".source = ./fish/config.fish;
    ".config/fish/fish_plugins".source = ./fish/fish_plugins;
    ".config/fish/functions" = {
      source = ./fish/functions;
      recursive = true;
    };
    ".config/fish/conf.d" = {
      source = ./fish/conf.d;
      recursive = true;
    };

    # Profile
    ".profile".source = ./profile;
  };

  # ============================================================================
  # ENVIRONMENT
  # ============================================================================
  home.sessionVariables = {
    PATH = "$HOME/.local/bin:$PATH";
    DBX_CONTAINER_MANAGER = "docker";
  };
}
