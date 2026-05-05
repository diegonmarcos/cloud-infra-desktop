# containers-cloud/observability.nix — telemetry server CLIs
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    prometheus
    grafana
  ];
}
