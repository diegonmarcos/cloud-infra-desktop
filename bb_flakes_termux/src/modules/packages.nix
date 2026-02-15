# Packages for Termux / nix-on-droid (CLI only, aarch64)
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # Nerd Fonts (for terminal icons)
    (nerdfonts.override { fonts = [ "JetBrainsMono" "FiraCode" ]; })

    # Modern CLI replacements
    eza
    bat
    fd
    ripgrep
    fzf
    zoxide
    btop
    ncdu
    duf
    tree
    yazi

    # JSON/YAML processing
    jq
    yq-go

    # File sync & transfer
    rclone

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

    # Process management
    procps

    # Network basics
    openssh

    # Other essentials
    file
    which
    diffutils

    # GitHub CLI
    gh

    # Secrets management
    sops
    age

    # Dev
    python312
    nodejs_20
    git

    # Cloud ops
    google-cloud-sdk
    oci-cli

    # Container CLIs (remote only — no daemon on Android, talks to VMs via SSH)
    docker-client
    docker-buildx
    podman
  ];
}
