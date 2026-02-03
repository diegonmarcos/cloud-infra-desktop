# Profile 7: Productivity & Documents
# Office, notes, organization, browsers
{ config, pkgs, lib, ... }:

{
  # Brave browser with extensions
  programs.chromium = {
    enable = true;
    package = pkgs.brave;
    extensions = [
      { id = "nngceckbapebfimnlniiiahkandclblb"; }  # Bitwarden
    ];
  };

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
    kdePackages.dolphin          # Use KDE 6 version to match system konsole
    kdePackages.dolphin-plugins  # Git/SVN integration
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
