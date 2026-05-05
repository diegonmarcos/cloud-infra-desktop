# core/tui.nix — terminal UIs and viewers
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    yazi             # TUI file manager
    browsh           # terminal web browser (headless Firefox rendering)
    ncdu             # disk usage analyzer
    duf              # df replacement
    tree             # directory tree view
  ];
}
