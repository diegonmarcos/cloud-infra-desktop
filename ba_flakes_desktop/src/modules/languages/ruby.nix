# languages/ruby.nix — Ruby interpreter
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    ruby
  ];
}
