# languages/go.nix — Go toolchain + LSP + debugger
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    go
    gopls
    delve            # Go debugger
  ];

  home.sessionVariables.GOPATH = "$HOME/go";
}
