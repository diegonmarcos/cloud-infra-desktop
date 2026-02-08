# Tmux terminal multiplexer configuration
{ config, pkgs, lib, ... }:

{
  programs.tmux = {
    enable = true;

    clock24 = true;
    historyLimit = 10000;
    keyMode = "vi";
    mouse = true;
    prefix = "C-a";
    terminal = "screen-256color";
    baseIndex = 1;
    escapeTime = 0;

    extraConfig = ''
      # Unbind default prefix
      unbind C-b

      # Split panes
      bind | split-window -h -c "#{pane_current_path}"
      bind - split-window -v -c "#{pane_current_path}"
      unbind '"'
      unbind %

      # Navigate panes (vim-like)
      bind h select-pane -L
      bind j select-pane -D
      bind k select-pane -U
      bind l select-pane -R

      # Resize panes
      bind -r H resize-pane -L 5
      bind -r J resize-pane -D 5
      bind -r K resize-pane -U 5
      bind -r L resize-pane -R 5

      # Window navigation
      bind -r C-h select-window -t :-
      bind -r C-l select-window -t :+

      # Reload config
      bind r source-file ~/.config/tmux/tmux.conf \; display "Reloaded!"

      # Copy mode
      bind Escape copy-mode
      bind -T copy-mode-vi 'v' send -X begin-selection
      bind -T copy-mode-vi 'y' send -X copy-selection-and-cancel
      bind -T copy-mode-vi 'V' send -X rectangle-toggle

      # Status bar
      set -g status-position top
      set -g status-style 'bg=#1a1b26 fg=#a9b1d6'
      set -g status-left '#[fg=green,bold][#S] '
      set -g status-right '#[fg=cyan]%H:%M #[fg=white]%Y-%m-%d'
      set -g status-left-length 30
      set -g status-right-length 50

      # Window status
      set -g window-status-format '#[fg=gray]#I:#W'
      set -g window-status-current-format '#[fg=cyan,bold]#I:#W'
      set -g window-status-separator ' '

      # Pane borders
      set -g pane-border-style 'fg=#3b4261'
      set -g pane-active-border-style 'fg=#7aa2f7'

      # Message style
      set -g message-style 'bg=#1a1b26 fg=#7aa2f7'

      # Pane numbers
      set -g display-panes-colour '#3b4261'
      set -g display-panes-active-colour '#7aa2f7'

      # Activity monitoring
      setw -g monitor-activity on
      set -g visual-activity off

      # Automatic renaming
      setw -g automatic-rename on
      set -g set-titles on
      set -g set-titles-string '#h: #S #I #W'

      # True color support
      set -ga terminal-overrides ",xterm-256color:Tc"
    '';
  };
}
