# data-science/api-clients.nix — Python HTTP clients + validation
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    python312Packages.requests
    python312Packages.httpx
    python312Packages.pydantic
  ];
}
