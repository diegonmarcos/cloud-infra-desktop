# Profile 1: Shell & Core Utilities
# Daily CLI operations, navigation, file management
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # Modern CLI replacements
    eza              # ls replacement with icons
    bat              # cat with syntax highlighting
    fd               # find replacement
    ripgrep          # grep replacement
    fzf              # fuzzy finder
    zoxide           # smart cd (frecency)
    yazi             # TUI file manager
    btop             # resource monitor
    ncdu             # disk usage analyzer
    duf              # df replacement
    tree             # directory tree view

    # JSON/YAML processing
    jq
    yq-go

    # File sync & transfer
    rsync
    rclone

    # Clipboard
    xclip
    wl-clipboard

    # Core utilities
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    curl
    wget
    htop
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

    # Other essentials
    file
    which
    diffutils
    patch

    # GitHub CLI
    gh
  ];
}
