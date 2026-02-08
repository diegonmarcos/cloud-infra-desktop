# FZF - Fuzzy Finder with shell integration
{ config, pkgs, ... }:

{
  programs.fzf = {
    enable = true;

    # Enable shell integrations
    enableZshIntegration = true;
    enableBashIntegration = true;
    enableFishIntegration = true;

    # Default command - use fd for faster search
    defaultCommand = "fd --type f --hidden --follow --exclude .git";

    # Ctrl+T - file search
    fileWidgetCommand = "fd --type f --hidden --follow --exclude .git";
    fileWidgetOptions = [
      "--preview 'bat --style=numbers --color=always --line-range :500 {} 2>/dev/null || cat {}'"
      "--preview-window 'right:50%:wrap'"
    ];

    # Alt+C - cd into directory
    changeDirWidgetCommand = "fd --type d --hidden --follow --exclude .git";
    changeDirWidgetOptions = [
      "--preview 'eza --tree --level=2 --color=always {} | head -200'"
    ];

    # Ctrl+R - history search (default, but with better options)
    historyWidgetOptions = [
      "--sort"
      "--exact"
    ];

    # Colors - match breeze dark theme
    colors = {
      fg = "#fcfcfc";
      bg = "#2a2e32";
      hl = "#3daee9";
      "fg+" = "#fcfcfc";
      "bg+" = "#31363b";
      "hl+" = "#3daee9";
      info = "#27ae60";
      prompt = "#3daee9";
      pointer = "#da4453";
      marker = "#27ae60";
      spinner = "#f67400";
      header = "#3daee9";
    };

    # Default options
    defaultOptions = [
      "--height 40%"
      "--layout=reverse"
      "--border"
      "--inline-info"
      "--bind 'ctrl-/:toggle-preview'"
      "--bind 'ctrl-a:select-all'"
      "--bind 'ctrl-y:execute-silent(echo {+} | wl-copy)'"
    ];
  };
}
