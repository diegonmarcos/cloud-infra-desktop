# WireGuard configuration for Termux (Android)
# Creates symlinks from vault to ~/.config/wireguard/
#
# Two endpoint variants (Phase 4 hub-side NAT redirect on gcp-proxy):
#   wg0.conf          -> vault/termux/config            (Endpoint = HUB:51820, primary)
#   wg0-fallback.conf -> vault/termux/config-fallback   (Endpoint = HUB:443,   fallback)
#
# Switch at runtime (no rebuild):
#   wg-quick down wg0          && wg-quick up wg0-fallback   # primary -> fallback
#   wg-quick down wg0-fallback && wg-quick up wg0            # fallback -> primary
#
# The vault-side file vault/A0_keys/providers/wireguard/termux/config-fallback
# must exist (same as `config` but with `Endpoint = 35.226.147.64:443`).
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

  # Phase 4 fallback (udp/443 -> udp/51820 NAT on gcp-proxy)
  home.file.".config/wireguard/wg0-fallback.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux/config-fallback";
  };

  home.sessionVariables.WIREGUARD_IP = "10.0.0.9";
}
