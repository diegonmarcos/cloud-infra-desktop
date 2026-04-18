# Profile 3: Build & Debug Tools
# Compilation, testing, analysis
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

    # Documentation & Diagrams
    pandoc
    doxygen
    graphviz         # dot — network graphs, auto-layout
    d2               # Architecture diagrams, clean modern style
    plantuml         # UML, sequence diagrams, enterprise
    pikchr           # Inline SVG, precise positioning
    # structurizr-cli is not in nixpkgs — use plantuml C4 stdlib instead

    # Version control extras
    git-lfs
    diff-so-fancy
    delta            # Better git diff

    # Testing
    act              # Run GitHub Actions locally

    # Development utilities
    direnv
    just             # Command runner
    watchexec        # Watch files and execute commands
  ];
}
