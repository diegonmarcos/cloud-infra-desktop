# Home-manager user-level packages (Termux / nix-on-droid, aarch64)
# System-level packages live in flake.nix → environment.packages
{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    busybox          # httpd — lightweight static file server
    mdbook
    tree
    netcat-openbsd  # nc — WireGuard peer probing in mesh.sh
    ncurses          # clear, tput
  ];
}
