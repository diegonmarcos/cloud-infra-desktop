# Hardware orchestrator — imports all hardware submodules
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./hardware_surface.nix
    ./hardware_filesystems.nix
    # Declarative bootloader modules - Source: aa_bootloader/src/
    # GENERATED FROM aa_bootloader/dist/adapters/nixos/ — do not edit copies in modules/
    ./hardware_bootloader_grub.nix  # GRUB settings + multi-OS entries (still imports for cmdline policy)
    ./hardware_bootloader_boot.nix  # LUKS + initrd + kernel modules
    ./swap_hibernate.nix            # swapDevices + boot.resumeDevice + resume= kernelParams
    ./grub_disable.nix              # NixOS yields ALL bootloader install — aa_bootloader owns /boot writes
  ];
}
