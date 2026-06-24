# productivity/pdf.nix — PDF viewers + extraction tools
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    kdePackages.okular    # 25.05: top-level alias removed, use kdePackages
    zathura
    poppler_utils    # pdftotext, etc.
  ];
}
