# ai/ant.nix — Anthropic Claude Developer Platform CLI
# Released 2026-04-08 alongside Managed Agents. Single Go binary, official
# upstream releases.
{ config, pkgs, lib, ... }:
{
  home.packages = [
    (pkgs.callPackage ../../pkgs/ant.nix {})
  ];
}
