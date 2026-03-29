# Profile 2: Development Languages
# Compilers, interpreters, runtimes
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # Rust (unstable channel for latest rustc/cargo)
    unstable.rustc
    unstable.cargo
    unstable.rust-analyzer
    unstable.clippy
    unstable.rustfmt
    cargo-edit
    cargo-watch
    cargo-audit
    pkg-config
    openssl

    # Code analysis
    (callPackage ../../pkgs/octocode.nix {})  # ../../ from modules/profiles/ → src/pkgs/

    # Go
    go
    gopls
    delve            # Go debugger

    # Node.js
    nodejs_20
    nodePackages.pnpm
    nodePackages.npm
    nodePackages.yarn
    nodePackages.typescript  # tsc
    esbuild                  # JS/TS bundler
    dart-sass                # SCSS compiler (sass CLI)

    # Python
    python312
    python312Packages.pip
    python312Packages.virtualenv
    pipx             # Install Python apps in isolated environments
    uv               # Fast Python package manager

    # C/C++ (only gcc - clang collides on c++/cc)
    gcc
    # clang      # collision with gcc on c++/cc binaries
    llvm
    lldb

    # Java
    jdk

    # Other languages
    ruby
  ];

  # Environment variables for languages
  home.sessionVariables = {
    CARGO_HOME = "$HOME/.cargo";
    GOPATH = "$HOME/go";
    npm_config_prefix = "$HOME/.npm-global";
  };
}
