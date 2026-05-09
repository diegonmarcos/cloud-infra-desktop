# Cloud Network: WireGuard PUBLIC mesh client (zany-popping plan Phase 1)
#
# Surface laptop joins the wg-public mesh (10.1.0.0/24) as a client peer in
# parallel to wg0. The interface itself is declared by the NixOS host
# (aa_desk-usr_x86_surface-linux_nixos/src/modules/configuration_network.nix)
# which expects:
#   /home/diego/.config/wireguard/privatekey-public   (this file → vault)
#   /home/diego/.config/wireguard/wg-public.conf      (runtime wg-quick config, optional)
#
# This module symlinks the vault entries declaratively so the host-level
# `networking.wireguard.interfaces.wg-public` definition resolves them.
#
# Source of truth: ~/git/cloud/2_configs/dist/build-flakes_desktop.json
#                  .wireguard_public.{peers,clients}
{ config, lib, pkgs, ... }:
let
  vaultBase = "${config.home.homeDirectory}/git/vault/A0_keys/providers/wireguard";
in {
  # Private key — consumed by NixOS host's networking.wireguard interface
  home.file.".config/wireguard/privatekey-public" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/surface-public/privatekey";
  };

  home.file.".config/wireguard/publickey-public" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/surface-public/publickey";
  };

  # Optional wg-quick conf (lets `wg-quick up wg-public` work as a fallback
  # path when the systemd networking.wireguard interface is unavailable, e.g.
  # live ISO or pre-rebuild boot). Only symlinked if vault has the file.
  home.file.".config/wireguard/wg-public.conf" = lib.mkIf (builtins.pathExists "${vaultBase}/surface-public/config") {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/surface-public/config";
  };

  # Surface-side WG IP advertisement for tooling (alongside WIREGUARD_IP=10.0.0.5
  # set elsewhere for wg0). Kept as an additional env var so existing wg0
  # consumers are not affected.
  home.sessionVariables.WIREGUARD_PUBLIC_IP = "10.1.0.5";
}
