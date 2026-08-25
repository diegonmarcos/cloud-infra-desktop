# languages/rust.nix — Rust analysers + Rust-built CLIs
# Rust toolchain itself (rustc, cargo, cargo subcommands, cargo-installed bins)
# is managed by ../rust-cargo-deps.nix, imported globally via userModules in
# flake.nix. This leaf only carries the analyser binaries we want regardless
# of toolchain choice.
{ config, pkgs, lib, ... }:
{
  # octocode removed 2026-08-25: the code graph is built and served in GHA/oci-apps
  # (cloud-cgc-*-mcp); nothing indexes on the desktop.
  home.packages = with pkgs; [ ];
}
