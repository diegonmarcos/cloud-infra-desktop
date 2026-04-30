# Profile 7: Productivity & Documents
# Office, notes, organization, browsers
{ config, pkgs, lib, ... }:

{
  # Brave + Firefox — each has its own dedicated declarative module.
  # - brave.nix:   Brave + brave-gpu wrapper (HW-accelerated Chromium-side)
  # - firefox.nix: Firefox configured for Vulkan-backed WebGPU + WebRender
  #                + VAAPI (the Vulkan path Brave can't reach on KWin)
  imports = [ ../brave.nix ../firefox.nix ];

  home.packages = with pkgs; [
    # firefox installed via ../firefox.nix above (programs.firefox.enable)

    # Office suite
    libreoffice

    # Note-taking
    obsidian
    zettlr
    joplin-desktop

    # PDF tools
    okular
    zathura
    poppler_utils    # pdftotext, etc.

    # File managers
    kdePackages.dolphin          # Use KDE 6 version to match system konsole
    kdePackages.dolphin-plugins  # Git/SVN integration
    ranger
    mc               # Midnight Commander

    # Archive tools
    kdePackages.ark              # Archive manager (GUI)
    p7zip
    unrar
    unzip
    zip

    # KDE utilities
    kdePackages.kate             # Advanced text editor
    kdePackages.kcalc            # Calculator
    kdePackages.spectacle        # Screenshot tool
    kdePackages.kmousetool       # Accessibility - auto-click
    kdePackages.partitionmanager # Disk partition manager
    kdePackages.filelight        # Disk usage visualizer
    kdePackages.kcharselect      # Character selector
    kdePackages.ksystemlog       # System log viewer
    kdePackages.kfind            # File search
    kdePackages.krdc             # Remote desktop client
    kdePackages.krfb             # Remote desktop server (VNC)
    kdePackages.skanlite         # Scanner app
    zenity                       # GTK dialog helper (used by scripts)
    kdialog                      # KDE dialog helper (used by scripts)

    # Task management
    taskwarrior
    vit              # Visual task interface

    # Calendar & Time
    calcurse
    remind

    # Screenshots
    flameshot
    maim

    # Markdown
    mdcat
    glow

    # Spell check
    aspell
    aspellDicts.en
    aspellDicts.es
  ];
}
