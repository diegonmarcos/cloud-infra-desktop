# Cloud Network: WireGuard mesh + Hickory DNS configuration
# Sets up WG peer config and DNS resolution for .app private names
#
# WG interface is declared by the NixOS host
# (aa_desk-usr_x86_surface-linux_nixos/src/modules/configuration_network.nix),
# whose `networking.wireguard.interfaces.wg0.privateKeyFile` expects:
#   /home/diego/.config/wireguard/privatekey   (this file → vault)
# This module (a) symlinks that private key from the vault, declaratively,
# mirroring cloud-network-wg-public.nix for the wg-public mesh, and
# (b) adds DNS routing so .app names resolve via Hickory (10.0.0.1).
#
# Source of truth: ~/git/cloud/2_configs/dist/build-flakes_desktop.json (.wireguard slice)
# Emitted by 2_configs/src/engines/cloud-data-config-derive.ts via external-consumers.json.
{ config, lib, pkgs, ... }:

let
  # WG mesh DNS server (Hickory on gcp-proxy)
  hickoryDns = "10.0.0.1";
  wgInterface = "wg0";
  # Domains that should resolve via Hickory (private .app names)
  wgDomains = [ "~app" ];
  wgDomainsStr = lib.concatStringsSep " " wgDomains;
  # Vault key material — same base as cloud-network-wg-public.nix.
  vaultBase = "${config.home.homeDirectory}/git/vault/A0_keys/providers/wireguard";

  # wg-dns-up / wg-dns-down: shell bodies live in ./wg-dns-up.sh and
  # ./wg-dns-down.sh, data-driven at runtime from
  # cloud-network-wg-dns.json (declared below via xdg.configFile, per the
  # wireguard-wstunnel precedent) instead of hickoryDns/wgInterface/wgDomains
  # being Nix-interpolated straight into the unit's ExecStart/ExecStop.
  # Store paths (jq, ip, dig) arrive via runtimeEnv.
  wgDnsUpScript = pkgs.writeShellApplication {
    name = "wg-dns-up";
    runtimeInputs = [ pkgs.jq pkgs.iproute2 pkgs.dnsutils ];
    runtimeEnv = {
      WG_DNS_JQ_BIN  = "${pkgs.jq}/bin/jq";
      WG_DNS_IP_BIN  = "${pkgs.iproute2}/bin/ip";
      WG_DNS_DIG_BIN = "${pkgs.dnsutils}/bin/dig";
    };
    text = builtins.readFile ./wg-dns-up.sh;
  };
  wgDnsDownScript = pkgs.writeShellApplication {
    name = "wg-dns-down";
    runtimeInputs = [ pkgs.jq ];
    runtimeEnv = {
      WG_DNS_JQ_BIN = "${pkgs.jq}/bin/jq";
    };
    text = builtins.readFile ./wg-dns-down.sh;
  };
in {
  # Runtime data for wg-dns-up / wg-dns-down.
  xdg.configFile."cloud-data/cloud-network-wg-dns.json".source = ./cloud-network-wg-dns.json;

  # ── wg0 private key ────────────────────────────────────────
  # Consumed by the NixOS host's networking.wireguard.interfaces.wg0.
  # Out-of-store symlink so the live vault file is read at runtime (the key
  # never enters the Nix store). Vault dir `surface/` (per-host layout) holds
  # this machine's wg0 key; its public key ii4FHx… (10.0.0.5) is what every
  # hub's cloud-data lists as the `surface` peer. The old `ssh_asymmetric/`
  # path was removed when the vault moved to per-host dirs (dangling symlink
  # → wireguard-wg0.service failed with `fopen: No such file or directory`).
  home.file.".config/wireguard/privatekey" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/surface/privatekey";
  };

  # ── systemd-resolved split DNS ─────────────────────────────
  # When wg0 is up, route .app queries to Hickory DNS (10.0.0.1)
  # Other queries (google.com etc) still go through system DNS (8.8.8.8)
  #
  # This uses systemd user service that runs resolvectl after wg0 comes up.
  # Requires systemd-resolved on the host (NixOS default).

  systemd.user.services.wg-dns-config = {
    Unit = {
      Description = "Configure DNS for WireGuard mesh (.app → Hickory)";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${wgDnsUpScript}/bin/wg-dns-up";
      ExecStop = "${wgDnsDownScript}/bin/wg-dns-down";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # ── WireGuard mesh info (for scripts/tools) ────────────────
  home.sessionVariables = {
    WG_INTERFACE = wgInterface;
    WG_DNS = hickoryDns;
    WG_LOCAL_IP = "10.0.0.5";
    WG_HUB_IP = "10.0.0.1";
    WG_HUB_ENDPOINT = "35.226.147.64:51820";
  };
}
