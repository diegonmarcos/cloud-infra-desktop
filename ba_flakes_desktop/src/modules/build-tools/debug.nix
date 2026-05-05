# build-tools/debug.nix — runtime debuggers / tracers
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    gdb
    lldb
    valgrind
    strace
    ltrace
  ];
}
