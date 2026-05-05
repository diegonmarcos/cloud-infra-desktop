# build-tools/analysis.nix — static analysis / linters / formatters
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    clang-tools      # clang-format, clang-tidy
    cppcheck
    shellcheck
    shfmt
  ];
}
