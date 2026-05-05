# core/data-formats.nix — JSON/YAML processors
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    jq
    yq-go
  ];
}
