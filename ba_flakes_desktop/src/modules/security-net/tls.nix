# security-net/tls.nix — TLS / web request tools
# (openssl lives in security-net/secrets.nix alongside other crypto primitives.)
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    httpie
    certbot
  ];
}
