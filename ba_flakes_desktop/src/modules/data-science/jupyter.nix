# data-science/jupyter.nix — Jupyter notebook stack
# `jupyter` meta-package is intentionally NOT installed: it creates a
# python3-env that collides with the individual python312Packages.* below.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    python312Packages.jupyterlab
    python312Packages.notebook
    python312Packages.ipython
  ];

  home.sessionVariables.JUPYTER_CONFIG_DIR = "$HOME/.config/jupyter";
}
