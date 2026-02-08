{ pkgs ? import <nixpkgs> {} }:

# Diego's CLI Development Container
#
# Build:  nix-build container.nix
# Load:   docker load < result
# Run:    docker run -it --rm -v $HOME:/home/diego diego-dev:latest
#
# Or with Podman/Distrobox:
#   podman load < result
#   distrobox create -n dev -i diego-dev:latest

pkgs.dockerTools.buildImage {
  name = "diego-dev";
  tag = "latest";

  copyToRoot = pkgs.buildEnv {
    name = "image-root";
    paths = with pkgs; [
      # ============================================
      # SHELLS
      # ============================================
      bash
      zsh
      fish
      starship

      # ============================================
      # C/C++ DEVELOPMENT
      # ============================================
      clang
      gcc
      gnumake
      cmake
      lldb
      gdb
      valgrind

      # ============================================
      # PYTHON
      # ============================================
      python3
      python3Packages.pip
      poetry

      # ============================================
      # NODE.JS
      # ============================================
      nodejs
      nodePackages.npm

      # ============================================
      # RUST
      # ============================================
      rustc
      cargo

      # ============================================
      # GIT & VERSION CONTROL
      # ============================================
      git
      gh              # GitHub CLI

      # ============================================
      # MODERN CLI TOOLS
      # ============================================
      ripgrep         # rg - fast grep
      fd              # fast find
      bat             # cat with syntax highlighting
      eza             # modern ls
      fzf             # fuzzy finder
      jq              # JSON processor
      yq              # YAML processor
      tree
      htop
      ncdu            # disk usage

      # ============================================
      # ARCHIVE TOOLS
      # ============================================
      unzip
      zip
      p7zip
      unrar
      gnutar
      gzip
      bzip2
      xz
      zstd

      # ============================================
      # NETWORK TOOLS
      # ============================================
      curl
      wget
      nettools        # netstat
      iproute2        # ip
      openssh
      rsync
      rclone

      # ============================================
      # SYSTEM UTILS
      # ============================================
      coreutils
      findutils
      gnugrep
      gnused
      gawk
      less
      which
      file
      procps          # ps, free, etc.

      # ============================================
      # EDITORS (CLI)
      # ============================================
      nano
      vim
    ];
    pathsToLink = [ "/bin" "/lib" "/share" ];
  };

  config = {
    Cmd = [ "/bin/fish" ];
    WorkingDir = "/home/diego";
    Env = [
      "PATH=/bin:/usr/bin"
      "HOME=/home/diego"
      "SHELL=/bin/fish"
    ];
  };
}
