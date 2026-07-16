# containers-cloud/containers.nix — OCI runtimes, Compose, image tools
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    docker-client
    podman
    youki            # Rust OCI runtime — replaces runc (Go)
    buildah
    skopeo
    oras             # OCI registry CLI — per-path nix cache pull in build.sh switch (nixcache_switch)
    dive             # Docker image analyzer
    docker-compose
    docker-buildx
  ];
}
