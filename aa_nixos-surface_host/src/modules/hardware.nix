# Hardware orchestrator — imports all hardware submodules
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./hardware_surface.nix
    ./hardware_boot.nix
    ./hardware_filesystems.nix
    ./grub.nix
  ];
}
