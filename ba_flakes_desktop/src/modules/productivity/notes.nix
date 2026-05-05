# productivity/notes.nix — note-taking apps (Electron-heavy)
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    obsidian
    zettlr
    joplin-desktop
  ];
}
