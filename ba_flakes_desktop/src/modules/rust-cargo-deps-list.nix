# Static list of Rust/Cargo Nix packages — always installed.
# Declarative baseline for the Rust toolchain and cargo subcommands.
{ lib, ... }:

{
  options.rustCargoDeps.nixPackages = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "Nix package attr names for Rust toolchain and cargo subcommands";
  };

  config.rustCargoDeps.nixPackages = [
    # Toolchain (unstable for latest versions)
    "unstable.rustc"
    "unstable.cargo"
    "unstable.rust-analyzer"
    "unstable.clippy"
    "unstable.rustfmt"

    # Cargo subcommands
    "cargo-edit"       # cargo add/rm/upgrade
    "cargo-watch"      # cargo watch -x check
    "cargo-audit"      # security audit

    # Build dependencies (needed by many crates)
    "pkg-config"
    "openssl"
  ];
}
