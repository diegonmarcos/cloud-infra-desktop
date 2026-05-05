# languages/node.nix — Node.js runtime + package managers + JS/TS toolchain
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    nodejs_20
    nodePackages.pnpm
    nodePackages.npm
    nodePackages.yarn
    nodePackages.typescript  # tsc
    esbuild                  # JS/TS bundler
    dart-sass                # SCSS compiler (sass CLI)
  ];

  home.sessionVariables.npm_config_prefix = "$HOME/.npm-global";
}
