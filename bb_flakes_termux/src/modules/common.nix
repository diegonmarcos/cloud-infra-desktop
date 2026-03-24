# Common configuration for Termux / nix-on-droid
{ config, pkgs, lib, ... }:

{
  imports = [
    ./programs/shells/bash.nix
    ./programs/shells/fish.nix
    ./programs/shells/fish-greeting.nix
    ./programs/shells/starship.nix
    ./programs/editors/vim.nix
    ./programs/git.nix
    ./programs/tmux.nix
  ];

  programs.home-manager.enable = true;

  nix = {
    package = pkgs.nix;
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      warn-dirty = false;
    };
  };

  home.sessionVariables = {
    EDITOR = "vim";
    VISUAL = "vim";
    PAGER = "less";
    LANG = "en_US.UTF-8";
    LC_ALL = "en_US.UTF-8";
    LESS = "-R -F -X";

    # Octocode — OpenAI-compatible endpoint (Ollama on oci-apps)
    OPENAI_BASE_URL = "http://10.0.0.6:11435/v1";
    OPENAI_API_KEY = "sk-dummy";
  };

  # Goose AI CLI config (cloud-ai-cli alias)
  home.file.".config/goose/config.yaml".source = ./dotfiles/goose/config.yaml;

  home.sessionPath = [
    "$HOME/.cargo/bin"
    "$HOME/.npm-global/bin"
    "$HOME/go/bin"
    "$HOME/.nix-profile/bin"
  ];

  nixpkgs.config.allowUnfree = true;
  news.display = "silent";
}
