# languages/c-cpp.nix — C/C++ compiler chain
# clang is intentionally NOT included here: it collides with gcc on c++/cc
# binary names. Use the gcc toolchain by default; clang-tools (formatter,
# tidy) lives under build-tools/analysis.nix.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    gcc
    llvm
    lldb
  ];
}
