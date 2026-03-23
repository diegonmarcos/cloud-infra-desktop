# WireGuard configuration for Termux (Android)
# Creates symlinks from vault to ~/.config/wireguard/
{ config, pkgs, lib, ... }:

let
  vaultBase = "${config.home.homeDirectory}/storage/shared/git/vault/A0_keys/providers/wireguard";
in
{
  home.file.".config/wireguard/privatekey" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux/privatekey";
  };

  home.file.".config/wireguard/publickey" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux/publickey";
  };

  home.file.".config/wireguard/wg0.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux/config";
  };

  home.sessionVariables.WIREGUARD_IP = "10.0.0.9";
}
