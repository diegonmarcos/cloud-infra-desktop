# languages/node.nix — Node.js runtime + package managers + JS/TS toolchain
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    # nodejs_22: align with the rest of the repo (node-npm-deps*.nix,
    # claude-code) and keep it as THE node on PATH. nodePackages.{pnpm,npm,
    # yarn,typescript} below propagate their build-time default node (nodejs_20
    # in this nixpkgs pin) onto PATH, which collides with bin/node here. hiPrio
    # makes nodejs_22's binaries win that symlink collision — enforcing the
    # documented intent instead of leaving it to derivation ordering.
    (lib.hiPrio nodejs_22)
    nodePackages.pnpm
    nodePackages.npm
    nodePackages.yarn
    nodePackages.typescript  # tsc
    esbuild                  # JS/TS bundler
    dart-sass                # SCSS compiler (sass CLI)
  ];

  home.sessionVariables.npm_config_prefix = "$HOME/.npm-global";
}
