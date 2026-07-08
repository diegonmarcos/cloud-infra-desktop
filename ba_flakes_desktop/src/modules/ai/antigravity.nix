# ai/antigravity.nix — Google Antigravity Desktop (agentic IDE, Electron)
# FHS-wrapped prebuilt tarball; see pkgs/antigravity.nix for source pinning.
{ config, pkgs, lib, ... }:
{
  home.packages = [
    (pkgs.callPackage ../../pkgs/antigravity.nix {})
  ];
}
