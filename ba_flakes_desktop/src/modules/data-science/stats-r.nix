# data-science/stats-r.nix — R + tidyverse subset
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    R
    rPackages.ggplot2
    rPackages.dplyr
    rPackages.tidyr
  ];
}
