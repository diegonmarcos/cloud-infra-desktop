# Packages for Termux / nix-on-droid (CLI only, aarch64)
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
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
  ];
}
