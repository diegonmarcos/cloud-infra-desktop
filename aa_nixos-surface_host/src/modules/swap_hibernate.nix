# Swap + hibernation resume — extracted from hardware_filesystems.nix
# GENERATED FROM aa_bootloader/src/boot.json
# DO NOT EDIT BY HAND — re-generate via: aa_bootloader/build.sh deploy --target nixos
#
# NOTE: `resume=` must be in boot.kernelParams explicitly. nixpkgs auto-injects
# `resume=${boot.resumeDevice}` only when boot.initrd.systemd.enable is true.
# This system uses the legacy initrd, so we set kernelParams explicitly.
{ config, lib, pkgs, ... }:

let
  bootCfg = builtins.fromJSON (builtins.readFile ./boot.json);
  sh = bootCfg.swap_hibernate;
in
{
  swapDevices = [{
    device = sh.swapfile;
  }];

  boot.resumeDevice = sh.resume_device;
  boot.kernelParams = sh.kernel_params;
}
