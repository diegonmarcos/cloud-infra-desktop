# data-science/python-ml.nix — ML / DL toolkits
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    python312Packages.scikit-learn
    python312Packages.torch
    python312Packages.torchvision
  ];
}
