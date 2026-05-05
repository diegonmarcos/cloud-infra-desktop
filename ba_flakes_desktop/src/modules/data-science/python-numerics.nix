# data-science/python-numerics.nix — numerical Python stack + plotting
# Owns the PYTHONPATH user-site sessionVariable since data-science is the
# canonical user of $HOME/.local/lib/python3.12/site-packages.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    python312Packages.numpy
    python312Packages.pandas
    python312Packages.scipy
    python312Packages.matplotlib
    python312Packages.seaborn
    python312Packages.plotly
    python312Packages.polars
    python312Packages.dask
    python312Packages.pyarrow
    python312Packages.bokeh
  ];

  home.sessionVariables.PYTHONPATH =
    "$HOME/.local/lib/python3.12/site-packages:$PYTHONPATH";
}
