# Shared Rust/Cargo toolchain — single source of truth for Rust dev environment.
#
# Architecture:
#   rust-cargo-deps.nix            ← this file (orchestrator: nix pkgs + env vars)
#   └── rust-cargo-deps-list.nix    ← static known deps (toolchain, cargo subcommands)
#
# NOTE: Unlike node-npm-deps.nix, Rust crates cannot be pre-compiled and shared
# across projects. Cargo compiles deps per crate root with fingerprinting that
# includes feature flags, profile settings, and dependency graph hashes.
# What IS shared: the registry cache (~/.cargo/registry) and within-workspace deps.
{ config, lib, pkgs, ... }:

let
  # Resolve "unstable.foo" / "foo" attr paths against pkgs
  resolvePkg = name:
    let
      parts = lib.splitString "." name;
    in
      if builtins.length parts == 2 && builtins.head parts == "unstable"
      then pkgs.unstable.${builtins.elemAt parts 1}
      else pkgs.${name};

  resolvedPackages = map resolvePkg config.rustCargoDeps.nixPackages;
in {
  imports = [
    ./rust-cargo-deps-list.nix
  ];

  # Install all nix-packaged Rust tools
  home.packages = resolvedPackages;

  # Environment
  home.sessionVariables = {
    CARGO_HOME = "$HOME/.cargo";
    # Shared target dir — keeps repos clean (no target/ in each project)
    CARGO_TARGET_DIR = "$HOME/.cargo/target";
  };
  home.sessionPath = [ "$HOME/.cargo/bin" ];
}
