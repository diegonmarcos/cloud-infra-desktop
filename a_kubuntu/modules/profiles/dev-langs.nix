# Dev Languages profile - Compilers and programming languages
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # Rust
    rustup
    cargo-edit
    cargo-watch
    cargo-audit

    # Go
    go
    gopls
    delve          # Go debugger

    # Node.js
    nodejs_20
    nodePackages.pnpm
    nodePackages.npm
    nodePackages.yarn

    # Python
    python312
    python312Packages.pip
    python312Packages.virtualenv
    pipx           # Install Python apps in isolated environments
    uv             # Fast Python package manager

    # C/C++
    gcc
    clang
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
    RUSTUP_HOME = "$HOME/.rustup";
    GOPATH = "$HOME/go";
    npm_config_prefix = "$HOME/.npm-global";
  };
}
