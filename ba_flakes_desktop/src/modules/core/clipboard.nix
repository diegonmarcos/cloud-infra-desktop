# core/clipboard.nix — clipboard tools (X11 + Wayland) and history
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    xclip
    wl-clipboard
    cliphist         # clipboard history (wl-paste --watch cliphist store)
  ];
}
