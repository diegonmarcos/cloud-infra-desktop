# Dev Tools profile - Build tools and debugging
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # Build systems
    cmake
    ninja
    gnumake
    meson
    automake
    autoconf
    libtool
    pkg-config

    # Debugging
    gdb
    lldb
    valgrind
    strace
    ltrace

    # Code analysis
    clang-tools      # clang-format, clang-tidy
    cppcheck
    shellcheck
    shfmt

    # Documentation
    pandoc
    doxygen
    graphviz

    # Container tools
    podman
    podman-compose
    buildah
    skopeo

    # Version control
    git-lfs
    diff-so-fancy
    delta            # Better git diff

    # Testing
    act              # Run GitHub Actions locally

    # Other development tools
    direnv
    just             # Command runner
    watchexec        # Watch files and execute commands
  ];
}
