# NixOS yield — tells NixOS NOT to manage the bootloader.
#
# This is NOT a bootloader configuration. It's a negation: it disables
# every NixOS bootloader module so NixOS skips grub-install, grub.cfg
# generation, NVRAM modification, and /boot/kernels placement.
#
# The actual bootloader (GRUB) is configured by aa_bootloader from
# /home/diego/git/unix/aa_bootloader/src/boot.json and deployed via
# `aa_bootloader/build.sh deploy --target grub`.
#
# Without this file, NixOS asserts `boot.loader.grub.devices` must be set.
# This file exists only to satisfy that assertion with `enable = false`.
{ config, lib, pkgs, ... }:
{
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
}
