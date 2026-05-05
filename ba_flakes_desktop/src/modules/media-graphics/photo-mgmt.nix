# media-graphics/photo-mgmt.nix — photo library manager
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    digikam
  ];
}
