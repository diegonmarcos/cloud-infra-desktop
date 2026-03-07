{ pkgs ? import <nixpkgs> {} }:

let
  # FHS files needed for Distrobox compatibility
  fhsFiles = pkgs.runCommand "fhs-files" {} ''
    mkdir -p $out/etc $out/tmp $out/var/tmp $out/run $out/home/diego

    # os-release for Distrobox
    cat > $out/etc/os-release << 'EOF'
NAME="NixOS"
ID=nixos
VERSION="unstable"
VERSION_ID="unstable"
PRETTY_NAME="NixOS (Diego CLI)"
HOME_URL="https://nixos.org"
EOF

    # passwd/group for user mapping
    echo "root:x:0:0:root:/root:/bin/bash" > $out/etc/passwd
    echo "diego:x:1000:1000:Diego:/home/diego:/bin/fish" >> $out/etc/passwd
    echo "root:x:0:" > $out/etc/group
    echo "diego:x:1000:" >> $out/etc/group
  '';
in

# ┌───────────────────────────────────────────────────────┐
# │ Diego's CLI Development Container                     │
# │                                                       │
# │ NIX (pinned, stable, heavy)                           │
# │ ├── Compilers: gcc, clang, rustc, go                  │
# │ ├── Big libs: openssl, zlib, glibc, llvm              │
# │ ├── System tools: git, curl, coreutils                │
# │ ├── Python interpreter                                │
# │ └── Poetry itself                                     │
# │                                                       │
# │   ┌───────────────────────────────────────────────┐   │
# │   │ POETRY (fast-moving, project-specific)        │   │
# │   │ ├── pypi packages                             │   │
# │   │ ├── Project deps (requests, pandas, etc.)     │   │
# │   │ └── Lock file per project                     │   │
# │   └───────────────────────────────────────────────┘   │
# └───────────────────────────────────────────────────────┘
#                         │
#                         ▼ OCI image
#                  ┌─────────────┐
#                  │   Podman    │
#                  └─────────────┘
#                         │
#                         ▼
#                  ┌─────────────┐
#                  │  Distrobox  │
#                  └─────────────┘
#
# Build:  nix-build container.nix
# Load:   podman load < result
# Create: distrobox create -n dev -i diego-cli:latest
# Enter:  distrobox enter dev

pkgs.dockerTools.buildImage {
  name = "diego-cli";
  tag = "latest";

  copyToRoot = pkgs.buildEnv {
    name = "image-root";
    paths = [
      fhsFiles  # Distrobox compatibility files
    ] ++ (with pkgs; [

      # ══════════════════════════════════════════════════════
      # SHELLS
      # ══════════════════════════════════════════════════════
      bash
      zsh
      fish
      starship
      kitty.terminfo    # terminfo for kitty

      # ══════════════════════════════════════════════════════
      # C/C++ COMPILERS & TOOLS
      # ══════════════════════════════════════════════════════
      gcc
      # clang           # DISABLED: collision with gcc (/bin/cpp)
      # clang-tools     # DISABLED: requires clang
      gnumake
      cmake
      ninja
      meson
      pkg-config
      bear              # compilation database generator

      # ══════════════════════════════════════════════════════
      # C/C++ DEBUGGERS & ANALYSIS
      # ══════════════════════════════════════════════════════
      gdb
      # lldb            # DISABLED: requires LLVM
      valgrind
      strace
      ltrace

      # ══════════════════════════════════════════════════════
      # C/C++ LIBRARIES (stable, big)
      # ══════════════════════════════════════════════════════
      openssl
      zlib
      libffi
      ncurses
      readline
      sqlite
      postgresql.lib
      libxml2
      libyaml

      # ══════════════════════════════════════════════════════
      # PYTHON (interpreter + Poetry)
      # ══════════════════════════════════════════════════════
      python311
      python311Packages.pip
      python311Packages.setuptools
      python311Packages.wheel
      python311Packages.virtualenv
      poetry

      # ══════════════════════════════════════════════════════
      # NODE.JS
      # ══════════════════════════════════════════════════════
      nodejs_20         # includes npm and npx
      # nodePackages.npm  # DISABLED: already in nodejs
      nodePackages.yarn

      # ══════════════════════════════════════════════════════
      # RUST (via rustup for flexibility)
      # ══════════════════════════════════════════════════════
      rustup

      # ══════════════════════════════════════════════════════
      # GO
      # ══════════════════════════════════════════════════════
      go

      # ══════════════════════════════════════════════════════
      # JAVA
      # ══════════════════════════════════════════════════════
      openjdk21

      # ══════════════════════════════════════════════════════
      # RUBY
      # ══════════════════════════════════════════════════════
      ruby              # includes bundler
      # bundler         # DISABLED: already in ruby
      jekyll

      # ══════════════════════════════════════════════════════
      # GIT & VERSION CONTROL
      # ══════════════════════════════════════════════════════
      git
      git-lfs
      gh                # GitHub CLI
      git-filter-repo

      # ══════════════════════════════════════════════════════
      # DOCUMENTATION
      # ══════════════════════════════════════════════════════
      pandoc
      doxygen
      graphviz
      mkdocs

      # ══════════════════════════════════════════════════════
      # MODERN CLI TOOLS
      # ══════════════════════════════════════════════════════
      ripgrep           # rg - fast grep
      fd                # fast find
      bat               # cat with syntax highlighting
      eza               # modern ls (exa replacement)
      fzf               # fuzzy finder
      jq                # JSON processor
      yq                # YAML processor
      tree
      htop
      btop
      ncdu              # disk usage analyzer
      pv                # pipe viewer
      watch

      # ══════════════════════════════════════════════════════
      # ARCHIVE & COMPRESSION
      # ══════════════════════════════════════════════════════
      gnutar
      gzip
      bzip2
      xz
      zstd
      unzip
      zip
      p7zip
      unrar

      # ══════════════════════════════════════════════════════
      # NETWORK TOOLS
      # ══════════════════════════════════════════════════════
      curl
      wget
      rsync
      rclone
      openssh
      nmap
      nettools          # netstat, ifconfig
      iproute2          # ip, ss
      iftop
      nethogs
      sshpass
      w3m               # text browser
      swaks             # SMTP testing

      # ══════════════════════════════════════════════════════
      # SYSTEM MONITORING & UTILS
      # ══════════════════════════════════════════════════════
      procps            # ps, free, top
      coreutils
      findutils
      gnugrep
      gnused
      gawk
      less
      which
      file
      lsof
      smem              # memory reporting

      # ══════════════════════════════════════════════════════
      # SHELL SCRIPTING & LINTING
      # ══════════════════════════════════════════════════════
      shellcheck
      shfmt

      # ══════════════════════════════════════════════════════
      # EDITORS (CLI)
      # ══════════════════════════════════════════════════════
      nano
      vim
      neovim

      # ══════════════════════════════════════════════════════
      # CLOUD & CONTAINER TOOLS
      # ══════════════════════════════════════════════════════
      # Note: podman runs on HOST, not inside container
      docker-client     # docker CLI (talks to host)

      # ══════════════════════════════════════════════════════
      # FILE MANAGERS (TUI)
      # ══════════════════════════════════════════════════════
      yazi              # terminal file manager
      ranger

      # ══════════════════════════════════════════════════════
      # MISC UTILITIES
      # ══════════════════════════════════════════════════════
      wakatime          # coding time tracker
      potrace           # bitmap to vector
      qrencode          # QR code generator
      zbar              # barcode/QR reader

      # ══════════════════════════════════════════════════════
      # CA CERTIFICATES (for HTTPS)
      # ══════════════════════════════════════════════════════
      cacert

    ]);
    pathsToLink = [ "/bin" "/lib" "/lib64" "/share" "/etc" "/include" ];
  };

  config = {
    Cmd = [ "/bin/fish" ];
    WorkingDir = "/home/diego";
    Env = [
      "PATH=/bin:/usr/bin:/home/diego/.local/bin:/home/diego/.cargo/bin"
      "HOME=/home/diego"
      "SHELL=/bin/fish"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "LANG=en_US.UTF-8"
    ];
  };
}
