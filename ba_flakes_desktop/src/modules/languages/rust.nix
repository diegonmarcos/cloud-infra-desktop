# languages/rust.nix — Rust analysers + Rust-built CLIs
# Rust toolchain itself (rustc, cargo, cargo subcommands, cargo-installed bins)
# is managed by ../rust-cargo-deps.nix, imported globally via userModules in
# flake.nix. This leaf only carries the analyser binaries we want regardless
# of toolchain choice.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    (callPackage ../../pkgs/octocode.nix {})  # Rust code-analysis CLI
  ];
}
