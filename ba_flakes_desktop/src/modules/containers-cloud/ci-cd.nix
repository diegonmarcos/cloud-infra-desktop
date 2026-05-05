# containers-cloud/ci-cd.nix — CI/CD runners and tooling
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    gitlab-runner
  ];
}
