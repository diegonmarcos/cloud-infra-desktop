# containers-cloud/iac.nix — Infrastructure-as-Code drivers
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    terraform
    ansible
    # packer     # DISABLED: builds from source (~20min)
  ];
}
