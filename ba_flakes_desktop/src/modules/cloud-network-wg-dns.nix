# Cloud Network: WireGuard mesh + Hickory DNS configuration
# Sets up WG peer config and DNS resolution for .app private names
#
# WG interface is created by NixOS host (aa_nixos-surface_host/configuration_network.nix)
# This module adds DNS routing so .app names resolve via Hickory (10.0.0.1)
#
# Source of truth: ~/git/cloud/cloud-data/cloud-data-wireguard-peers.json
{ config, lib, pkgs, ... }:

let
  # WG mesh DNS server (Hickory on gcp-proxy)
  hickoryDns = "10.0.0.1";
  wgInterface = "wg0";
  # Domains that should resolve via Hickory (private .app names)
  wgDomains = [ "~app" ];
in {
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

        echo "[wg-dns] Setting DNS for ${wgInterface} → ${hickoryDns}"
        sudo resolvectl dns ${wgInterface} ${hickoryDns}
        sudo resolvectl domain ${wgInterface} ${lib.concatStringsSep " " wgDomains}
        sudo resolvectl default-route ${wgInterface} false

        echo "[wg-dns] Verifying..."
        resolvectl status ${wgInterface} 2>/dev/null || true
        echo "[wg-dns] Done — .app names now resolve via Hickory"
      '';
      ExecStop = pkgs.writeShellScript "wg-dns-down" ''
        if ip link show ${wgInterface} >/dev/null 2>&1; then
          echo "[wg-dns] Reverting DNS for ${wgInterface}"
          sudo resolvectl revert ${wgInterface} 2>/dev/null || true
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
