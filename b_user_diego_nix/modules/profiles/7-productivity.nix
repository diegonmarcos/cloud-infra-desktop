# Profile 7: Productivity & Documents
# Office, notes, organization
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
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
    dolphin
    ranger
    mc               # Midnight Commander

    # Archive tools
    p7zip
    unrar
    unzip
    zip

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
