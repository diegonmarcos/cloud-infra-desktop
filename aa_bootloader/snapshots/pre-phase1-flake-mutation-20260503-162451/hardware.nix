# Hardware orchestrator — imports all hardware submodules
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./hardware_surface.nix
    ./hardware_filesystems.nix
    # Declarative bootloader modules - Source: aa_bootloader/src/
    ./hardware_bootloader_grub.nix  # GRUB settings + multi-OS entries
    ./hardware_bootloader_boot.nix  # LUKS + initrd + kernel modules
  ];
}
