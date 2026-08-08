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
  # ~/git/vault — the SAME path every other module uses (common.nix, the
  # curl/wget wrappers, claude settings env). The old value pointed at
  # ~/storage/shared/git/vault/… which doesn't exist, so every symlink
  # below dangled and "[wireguard-wstunnel] wg0.conf not found — skipping
  # render" fired on every switch since day one (found 2026-08-08).
  vaultBase = "${config.home.homeDirectory}/git/vault/A0_keys/providers/wireguard";
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

  # ── WireGuard PUBLIC mesh client (zany-popping plan Phase 1) ──────────────
  # Termux phone joins the wg-public mesh (10.1.0.0/24, hub = oci-analytics) as
  # a client peer in addition to wg0. Bring up with:
  #   wg-quick up wg-public
  # Vault key dir: vault/A0_keys/providers/wireguard/termux-public/
  # Source-of-truth peer table: ~/git/cloud/2_configs/dist/build-flakes_termux.json
  #                             .wireguard_public.{peers,clients.termux}
  home.file.".config/wireguard/privatekey-public" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux-public/privatekey";
  };

  home.file.".config/wireguard/publickey-public" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux-public/publickey";
  };

  # No pathExists gate: the closure is built in CI where the device path
  # never exists, so the mkIf was permanently false and wg-public.conf was
  # never deployed. mkOutOfStoreSymlink tolerates a missing target (the
  # symlink just dangles until the vault file appears).
  home.file.".config/wireguard/wg-public.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux-public/config";
  };

  home.sessionVariables = {
    WIREGUARD_IP = "10.0.0.9";
    WIREGUARD_PUBLIC_IP = "10.1.0.9";
  };
}
