# Host-side enable + config for the fido2-vault-broker NixOS module.
#
# The module itself lives in the daemon repo at
# `~/git/unix/da_fido2-vault-broker/src/nix/module.nix`, imported by PLAIN
# PATH in the host flake.nix modules list (NOT a flake input — nix 2.24
# cannot lock relative-path flake inputs; see the NOTE in flake.nix).
# Because the path import skips the subflake's package-defaulting wrapper,
# this file supplies the package via callPackage on the shared package.nix.
#
# What this enables (system-wide, declarative):
#   * boot.kernelModules += "uhid"   (loads the stock mainline uhid driver)
#   * services.udev.packages += [ fido2-vault-broker ] (ships the udev rule)
#   * users.groups.uhid + users.users.diego.extraGroups += ["uhid" "tss"]
#   * security.tpm2.enable = true    (creates `tss` group + /dev/tpmrm0 rules)
#   * environment.systemPackages += [ fido2-vault-broker ] (binary on PATH)
#
# The user-session systemd unit lives in the home-manager side
# (cb_user_diego_nix or wherever home-manager is configured). This file
# only owns the system-level integration.

{ pkgs, ... }:

{
  programs.fido2-vault-broker = {
    enable = true;
    user = "diego";
    enableTpm = true;
    # Shared derivation with the subflake's packages.default (single SoT).
    package = pkgs.callPackage ../../../da_fido2-vault-broker/src/nix/package.nix { };
  };
}
