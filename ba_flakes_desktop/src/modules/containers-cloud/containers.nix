# containers-cloud/containers.nix — OCI runtimes, Compose, image tools
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    docker-client
    podman
    youki            # Rust OCI runtime — replaces runc (Go)
    buildah
    skopeo
    dive             # Docker image analyzer
    docker-compose
    docker-buildx
  ];
}
