# Profile 1: Shell & Core Utilities
# Daily CLI operations, navigation, file management
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # Nerd Fonts (for terminal icons)
    (nerdfonts.override { fonts = [ "JetBrainsMono" "FiraCode" ]; })

    # Modern CLI replacements
    eza              # ls replacement with icons
    bat              # cat with syntax highlighting
    fd               # find replacement
    ripgrep          # grep replacement
    fzf              # fuzzy finder
    zoxide           # smart cd (frecency)
    atuin            # shell history search (arrow-up, Ctrl+R)
    tealdeer         # tldr — simplified man pages
    browsh           # terminal web browser (headless Firefox rendering)
    yazi             # TUI file manager
    btop             # resource monitor
    multitail        # multi-file tail with split view
    ncdu             # disk usage analyzer
    duf              # df replacement
    tree             # directory tree view

    # JSON/YAML processing
    jq
    yq-go

    # File sync & transfer
    rsync
    rclone
    wrangler

    # Clipboard
    xclip
    wl-clipboard
    cliphist         # clipboard history (wl-paste --watch cliphist store)

    # Core utilities
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    curl
    wget
    htop
    iotop
    sysstat      # iostat, mpstat, pidstat, sar
    less
    bc
    unzip
    zip
    p7zip

    # System info
    neofetch
    lshw
    pciutils
    usbutils

    # Process management
    procps
    psmisc

    # Network basics
    bind             # dig, nslookup
    dnsutils
    inetutils        # telnet, ftp, etc.
    openssh
    socat

    # Other essentials
    file
    which
    diffutils
    patch

    # Web terminal (Termux-style mobile keyboard)
    ttyd

    # Git extras
    git-filter-repo  # git history rewriting (purge secrets from commits)

    # GitHub CLI
    gh
  ];
}
