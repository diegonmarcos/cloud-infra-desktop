# security-net/privacy.nix — anonymity / DNS privacy
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    tor
    torsocks
    dnscrypt-proxy2
  ];
}
