# languages/python.nix — CPython + base packaging tools
# Heavier domain libs (numpy, torch, R, …) live under data-science/.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    python312
    python312Packages.pip
    python312Packages.virtualenv
    pipx             # install Python apps in isolated environments
    uv               # fast Python package manager
  ];
}
