# containers-cloud/cloud-clis.nix — vendor cloud CLIs
# Heavy single-vendor CLIs that don't deserve their own leaf live here. The
# really heavy ones (e.g. wrangler, ~898 MB) live under infra-tools/.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    google-cloud-sdk
    awscli2
    azure-cli
    oci-cli
    cloudflared
    flarectl
  ];
}
