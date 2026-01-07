# Base profile - Essential CLI tools
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # Core utilities
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    curl
    wget
    git
    htop
    less
    tree
    bc
    jq
    yq-go
    unzip
    zip
    p7zip

    # Modern CLI replacements
    eza           # ls replacement
    bat           # cat replacement with syntax highlighting
    fd            # find replacement
    ripgrep       # grep replacement
    fzf           # fuzzy finder
    zoxide        # smart cd
    yazi          # file manager TUI
    btop          # resource monitor
    ncdu          # disk usage analyzer
    duf           # df replacement

    # File sync & transfer
    rsync
    rclone

    # Clipboard
    xclip
    wl-clipboard

    # GitHub CLI
    gh

    # Network tools
    bind          # dig, nslookup
    dnsutils
    inetutils     # telnet, ftp, etc.
    openssh

    # Text processing
    gnugrep
    gnused
    gawk
    ripgrep

    # System info
    neofetch
    lshw
    pciutils
    usbutils

    # Process management
    procps
    psmisc

    # Other essentials
    file
    which
    diffutils
    patch
  ];
}
