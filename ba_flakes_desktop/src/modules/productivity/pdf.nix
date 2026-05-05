# productivity/pdf.nix — PDF viewers + extraction tools
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    okular
    zathura
    poppler_utils    # pdftotext, etc.
  ];
}
