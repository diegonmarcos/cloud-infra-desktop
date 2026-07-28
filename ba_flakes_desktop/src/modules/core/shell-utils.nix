# core/shell-utils.nix — modern CLI replacements for ls/cat/find/grep/cd
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    eza              # ls replacement with icons
    bat              # cat with syntax highlighting
    fd               # find replacement
    ripgrep          # grep replacement
    fzf              # fuzzy finder
    zoxide           # smart cd (frecency)
    atuin            # shell history search (arrow-up, Ctrl+R)
    tealdeer         # tldr — simplified man pages
    btop             # resource monitor (per-process, pretty)
    atop             # resource monitor (per-process + PSI + per-disk + per-net, dense)
    glances          # resource monitor (system + containers + sensors, all-in-one TUI)
    multitail        # multi-file tail with split view
  ];

  # ── Desktop entry for Glances web UI mode ──
  xdg.desktopEntries.glances = {
    name = "Glances (Web UI)";
    comment = "System monitor with web interface";
    exec = "glances -w --open-web-browser";
    icon = "utilities-system-monitor";
    terminal = false;
    categories = [ "System" "Monitor" ];
  };
}
