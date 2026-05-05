# infra-tools/wrangler.nix — Cloudflare Workers CLI (~898 MB)
# Isolated as its own leaf so it can be toggled independently of the rest of
# the cloud CLI bundle.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    wrangler
  ];
}
