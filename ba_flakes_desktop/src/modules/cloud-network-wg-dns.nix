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
  # Vault key material — same base as cloud-network-wg-public.nix.
  vaultBase = "${config.home.homeDirectory}/git/vault/A0_keys/providers/wireguard";
in {
  # ── wg0 private key ────────────────────────────────────────
  # Consumed by the NixOS host's networking.wireguard.interfaces.wg0.
  # Out-of-store symlink so the live vault file is read at runtime (the key
  # never enters the Nix store). Public key 9nL3Ub… = this machine (10.0.0.5).
  home.file.".config/wireguard/privatekey" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/ssh_asymmetric/privatekey";
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
      ExecStart = pkgs.writeShellScript "wg-dns-up" ''
        # Wait for wg0 interface to exist (max 10s)
        for i in $(seq 1 10); do
          if ip link show ${wgInterface} >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done

        if ! ip link show ${wgInterface} >/dev/null 2>&1; then
          echo "[wg-dns] ${wgInterface} not found — skipping DNS config"
          exit 0
        fi

        echo "[wg-dns] Adding ${hickoryDns} to resolv.conf for .app names"

        # Method 1: systemd-resolved (if available)
        if command -v resolvectl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
          echo "[wg-dns] Using systemd-resolved split DNS"
          sudo resolvectl dns ${wgInterface} ${hickoryDns}
          sudo resolvectl domain ${wgInterface} ${lib.concatStringsSep " " wgDomains}
          sudo resolvectl default-route ${wgInterface} false
        else
          # Method 2: Direct resolv.conf prepend (resolvconf/NetworkManager systems)
          echo "[wg-dns] Using resolv.conf prepend (no systemd-resolved)"
          if ! grep -q "${hickoryDns}" /etc/resolv.conf 2>/dev/null; then
            # Prepend Hickory as first nameserver
            sudo sed -i '1s/^/nameserver ${hickoryDns}\n/' /etc/resolv.conf
            echo "[wg-dns] Added nameserver ${hickoryDns} to /etc/resolv.conf"
          else
            echo "[wg-dns] ${hickoryDns} already in resolv.conf"
          fi
        fi

        echo "[wg-dns] Verifying: dig @${hickoryDns} authelia.app"
        dig @${hickoryDns} +short authelia.app 2>/dev/null || echo "(hickory not reachable — wg0 may need time)"
        echo "[wg-dns] Done"
      '';
      ExecStop = pkgs.writeShellScript "wg-dns-down" ''
        echo "[wg-dns] Removing ${hickoryDns} from resolv.conf"
        if command -v resolvectl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
          sudo resolvectl revert ${wgInterface} 2>/dev/null || true
        else
          sudo sed -i '/^nameserver ${hickoryDns}$/d' /etc/resolv.conf 2>/dev/null || true
        fi
      '';
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
