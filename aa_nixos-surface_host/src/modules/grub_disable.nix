# NixOS YIELDS bootloader authority — aa_bootloader owns everything
# GENERATED FROM aa_bootloader/src/adapters/nixos/grub_disable.nix
# DO NOT EDIT BY HAND — re-generate via aa_bootloader/build.sh deploy --target nixos
#
# After this module is imported:
#   - NixOS does NOT run grub-install
#   - NixOS does NOT regenerate /boot/grub/grub.cfg
#   - NixOS does NOT modify EFI NVRAM (no efibootmgr from nixos-rebuild)
#   - NixOS does NOT copy kernel/initrd to /boot/kernels/
#
# All of those are now owned by aa_bootloader. The flake's
# hardware_bootloader_grub.nix's `extraInstallCommands` will NOT fire
# anymore (because grub.enable=false skips the whole grub install path).
# Instead, deploy-grub.sh handles everything.
#
# Workflow becomes:
#   1. nixos-rebuild build .#surface  → builds new closure (no /boot writes)
#   2. nix-env --switch-generation    → bumps /nix/var/nix/profiles/system
#   3. aa_bootloader/build.sh deploy --target grub  → writes /boot
#
# build.sh deploy --target nixos chains all three.
{ config, lib, pkgs, ... }:
{
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
}
