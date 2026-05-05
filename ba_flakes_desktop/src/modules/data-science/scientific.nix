# data-science/scientific.nix — symbolic + numerical math beyond NumPy/SciPy
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    python312Packages.sympy
    octave
  ];
}
