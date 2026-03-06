# Common configuration shared by all hosts
{ config, pkgs, lib, ... }:

{
  imports = [
    ./programs/shells/bash.nix
    ./programs/shells/zsh.nix
    ./programs/shells/fish.nix
    ./programs/shells/starship.nix
    ./programs/shells/fzf.nix
    ./programs/editors/vim.nix
    ./programs/git.nix
    ./programs/tmux.nix
    ./programs/mesh.nix
    ./programs/cloud-connect.nix
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
    # Automatic garbage collection
    gc = {
      automatic = true;
      frequency = "weekly";
      options = "--delete-older-than 7d";
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

  # Claude Code configuration + MCP server config
  home.file.".claude/CLAUDE.md".source = ./dotfiles/claude/CLAUDE.md;
  home.file.".mcp.json".source = ./dotfiles/claude/mcp.json;
  home.file.".claude/statusline-command.sh" = {
    source = ./dotfiles/claude/statusline-command.sh;
    executable = true;
  };
  home.file.".claude/hooks/claude-memory.sh" = {
    source = ./dotfiles/claude/claude-memory.sh;
    executable = true;
  };
  home.file.".claude/settings.json".source = ./dotfiles/claude/settings.json;
  home.file.".rgignore".source = ./dotfiles/claude/rgignore;

  # Minimal .gitignore so $HOME is a git repo (ignore everything)
  # This makes Claude Code use `git ls-files` (instant) instead of ripgrep (97s timeout)
  home.file.".gitignore".text = "*";

  # Initialize $HOME as minimal git repo so Claude Code uses git ls-files (instant)
  # instead of ripgrep fallback (97s timeout scanning all of $HOME)
  home.activation.initHomeGit = lib.hm.dag.entryAfter ["linkGeneration"] ''
    if [ ! -d "$HOME/.git" ]; then
      $DRY_RUN_CMD ${pkgs.git}/bin/git init "$HOME" 2>/dev/null
    fi
    # Ensure .gitignore is tracked (it's a nix-managed symlink)
    $DRY_RUN_CMD ${pkgs.git}/bin/git -C "$HOME" add -f .gitignore 2>/dev/null || true
  '';
}
