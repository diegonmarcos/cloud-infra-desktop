# Common configuration shared by all hosts
{ config, pkgs, lib, ... }:

{
  imports = [
    ./programs/shells/bash.nix
    ./programs/shells/zsh.nix
    ./programs/shells/fish.nix
    ./programs/shells/starship.nix
    ./programs/editors/vim.nix
    ./programs/git.nix
    ./programs/tmux.nix
  ];

  # Enable Home Manager
  programs.home-manager.enable = true;

  # Nix settings
  nix = {
    package = pkgs.nix;
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      warn-dirty = false;
    };
  };

  # XDG Base Directory compliance
  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
      desktop = "${config.home.homeDirectory}/Desktop";
      documents = "${config.home.homeDirectory}/Documents";
      download = "${config.home.homeDirectory}/Downloads";
      music = "${config.home.homeDirectory}/Music";
      pictures = "${config.home.homeDirectory}/Pictures";
      videos = "${config.home.homeDirectory}/Videos";
    };
  };

  # Session variables
  home.sessionVariables = {
    EDITOR = "vim";
    VISUAL = "vim";
    PAGER = "less";
    MANPAGER = "less -R";

    # Locale
    LANG = "en_US.UTF-8";
    LC_ALL = "en_US.UTF-8";

    # Less options
    LESS = "-R -F -X";

    # Colored man pages
    LESS_TERMCAP_mb = "$(printf '\\e[1;31m')";
    LESS_TERMCAP_md = "$(printf '\\e[1;36m')";
    LESS_TERMCAP_me = "$(printf '\\e[0m')";
    LESS_TERMCAP_se = "$(printf '\\e[0m')";
    LESS_TERMCAP_so = "$(printf '\\e[1;44;33m')";
    LESS_TERMCAP_ue = "$(printf '\\e[0m')";
    LESS_TERMCAP_us = "$(printf '\\e[1;32m')";
  };

  # Session path additions
  home.sessionPath = [
    "$HOME/.local/bin"
    "$HOME/.cargo/bin"
    "$HOME/.npm-global/bin"
    "$HOME/go/bin"
    "$HOME/.nix-profile/bin"
  ];

  # Font configuration
  fonts.fontconfig.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Systemd user services (for Linux)
  systemd.user.startServices = "sd-switch";

  # News notifications
  news.display = "silent";
}
