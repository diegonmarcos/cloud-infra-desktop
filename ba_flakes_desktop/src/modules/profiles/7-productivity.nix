# Profile 7: Productivity & Documents
# Office, notes, organization, browsers
{ config, pkgs, lib, ... }:

{
  # Brave browser with extensions
  programs.chromium = {
    enable = true;
    package = pkgs.unstable.brave;
    extensions = [
      { id = "nngceckbapebfimnlniiiahkandclblb"; }  # Bitwarden
    ];
  };

  # Brave default homepage + new-tab page → local webserver on :8000
  # Brave reads managed policies from ~/.config/BraveSoftware/Brave-Browser/policies/managed/
  # (declarative; survives Brave updates; takes effect on next launch).
  home.file.".config/BraveSoftware/Brave-Browser/policies/managed/homepage-localhost-8000.json".text =
    builtins.toJSON {
      # On startup: open the configured URL list (4 = "Open a list of URLs")
      RestoreOnStartup = 4;
      RestoreOnStartupURLs = [ "http://localhost:8000" ];
      # Home button → localhost:8000
      HomepageLocation = "http://localhost:8000";
      HomepageIsNewTabPage = false;
      ShowHomeButton = true;
      # New tab → localhost:8000 (overrides Brave's default new-tab page)
      NewTabPageLocation = "http://localhost:8000";
    };

  home.packages = with pkgs; [
    # Browsers
    firefox

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
