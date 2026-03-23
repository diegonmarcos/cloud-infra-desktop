# GRUB bootloader: menu entries, EFI, multi-OS boot
{ config, lib, pkgs, ... }:

{
  boot.loader = {
    efi = {
      canTouchEfiVariables = true;
      efiSysMountPoint = "/boot/efi";
    };
    grub = {
      enable = true;
      device = "nodev";  # EFI install, not MBR
      efiSupport = true;
      efiInstallAsRemovable = false;

      # Default: NixOS (first entry, index 0)
      default = 0;

      # Include all other OSes (Kubuntu, Arch, Kali, Windows)
      extraEntries = import ../grub-extra-entries.nix;

      extraInstallCommands = ''
        ${pkgs.coreutils}/bin/mkdir -p /boot/efi/EFI/nixos
      '';
    };
  };
}
