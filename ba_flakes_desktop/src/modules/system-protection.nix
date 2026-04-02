# System Protection — Desktop (Surface Pro 8)
#
# NixOS-native protection (sysctl, zram, earlyoom) lives in the NixOS HOST flake:
#   unix/aa_nixos-surface_host/src/modules/configuration_system-protection.nix
#
# Home-manager handles:
#   - User-level guardrails (PATH wrapper scripts)
#   - Cgroup slice hierarchy (layer2-identity: kernel/os-essentials/workload slices)
#   - Resource bouncer (memory reserves, docker caps)
#   - Watchdog + Dropbear rescue SSH
{ config, pkgs, lib, ... }:

{
  _module.args = {
    ramMB = 7778;       # Surface Pro 8: 8GB
    cpus = 8;           # 4 cores × 2 threads
    userName = "diego";
    userId = 1000;
    rescuePort = 2200;  # Dropbear rescue SSH port
  };

  imports = [
    ./system-protection-guardrails.nix
    ./system-protection-layer2-identity.nix
    ./system-protection-resource-bouncer.nix
    ./system-protection-watchdog-dropbear.nix
  ];
}
