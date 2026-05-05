# ai/gemini.nix — Gemini CLI (custom package)
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    customPkgs.gemini-cli
    # customPkgs.cloud-infra-mcp  # TODO: define this custom package
  ];
}
