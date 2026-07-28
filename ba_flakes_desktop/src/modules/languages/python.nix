# languages/python.nix — CPython + base packaging tools
# Heavier domain libs (numpy, torch, R, …) live under data-science/.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    # Use a SINGLE withPackages env (not bare python312 + separate pip/virtualenv)
    # to avoid a bin/2to3 collision between python3-3.12.12 (bare interpreter)
    # and python3-3.12.12-env (the wrapper pip/virtualenv pull in).
    (python312.withPackages (p: [ p.pip p.virtualenv ]))
    pipx             # install Python apps in isolated environments
    uv               # fast Python package manager
  ];
}
