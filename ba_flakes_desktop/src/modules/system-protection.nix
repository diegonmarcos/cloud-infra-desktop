# System Protection — Desktop (Surface Pro 8)
#
# NixOS-native protection (sysctl, zram, earlyoom, cgroup slices, FIFO scheduler,
# rescue SSH, disk watchdog) lives in the NixOS HOST flake:
#   unix/aa_nixos-surface_host/src/modules/configuration_system-protection.nix
#
# Home-manager only handles user-level guardrails (PATH wrapper scripts).
{ config, pkgs, lib, ... }:

{
  imports = [
    ./system-protection-guardrails.nix
  ];
}
