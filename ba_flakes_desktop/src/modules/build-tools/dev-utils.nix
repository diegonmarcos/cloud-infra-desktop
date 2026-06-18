# build-tools/dev-utils.nix — generic dev workflow utilities
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    direnv
    just             # command runner
    watchexec        # watch files and execute commands
    act              # run GitHub Actions locally
    android-tools    # adb + fastboot — on-device diagnostics (USB-PD/charging, dumpsys)
  ];
}
