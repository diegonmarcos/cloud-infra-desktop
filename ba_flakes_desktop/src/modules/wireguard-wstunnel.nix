# Cloud Network — WireGuard-over-TCP/443 fallback (wstunnel client)
#
# Sibling of cloud-network-wg-dns.nix. This module is the LAPTOP side of the
# `bb-net_wireguard-mesh-ws-tunnel` cloud service: it runs wstunnel-client as
# a systemd-user service, tunneling UDP/127.0.0.1:51821 → WSS over TCP/443
# to the wstunnel-server on gcp-proxy. Activated only when on a network that
# blocks UDP/51820 (airport, hotel, captive portal); otherwise direct WG over
# UDP/51820 (configuration_network.nix wg0) is faster and preferred.
#
# Source of truth (data-driven, fire-rule 4 + 6):
#   ~/git/cloud/a_solutions/bb-net_wireguard-mesh-ws-tunnel/build.json
#     • .domain                        — the WSS server hostname
#     • .transports.wg0-tcp.endpoint_template
#     • .transports.wg0-tcp.wstunnel_path_prefix_secret  (env-var name)
#
# Secrets:
#   WSTUNNEL_PATH_PREFIX is read from $HOME/.config/wireguard/.wstunnel-secret
#   at activation time — populated by the existing sops-decrypt activation
#   that already provisions /home/diego/.config/wireguard/privatekey for wg0.
#
# Usage at runtime:
#   systemctl --user start wstunnel-client     # bring tunnel up
#   wg-quick up wg0-tcp                        # WG via local loopback
#   …captive-portal-survival enabled…
#   wg-quick down wg0-tcp
#   systemctl --user stop wstunnel-client
#
# Decommission: when migrating to Tailscale or removing the fallback, this
# module can be removed independently — the existing wireguard.nix / wg0
# direct-UDP path is untouched.

{ config, lib, pkgs, ... }:

let
  # ── Data sources (declarative cross-references, no inlined values) ──────
  wsTunnelBuildJson =
    let path = ../../../../cloud/a_solutions/bb-net_wireguard-mesh-ws-tunnel/build.json;
    in if builtins.pathExists path
       then builtins.fromJSON (builtins.readFile path)
       else null;

  # Resolve fields with graceful fallback (module is a no-op if cloud sibling
  # not checked out — useful for fresh clones / CI envs without ../cloud).
  vpnDomain   = if wsTunnelBuildJson != null then wsTunnelBuildJson.domain else "vpn.diegonmarcos.com";
  wsEndpoint  = "wss://${vpnDomain}:443";
  localUdp    = 51821;            # local loopback port wstunnel-client listens on
  remoteWg    = 51820;            # kernel WG listener on gcp-proxy (loopback after wstunnel-server unwraps)
  secretFile  = "${config.home.homeDirectory}/.config/wireguard/.wstunnel-secret";
  wgTcpConf   = "${config.home.homeDirectory}/.config/wireguard/wg0-tcp.conf";
  wstunnelBin = "${pkgs.wstunnel}/bin/wstunnel";
in
{
  # ── Package: wstunnel binary (Rust, ~10 MB RSS when active) ────────────
  home.packages = with pkgs; [
    wstunnel
  ];

  # ── systemd-user service: wstunnel-client tunnel ───────────────────────
  # Tunnels: local UDP/127.0.0.1:51821 → WSS over TCP/443 → wstunnel-server
  # on gcp-proxy → kernel WG at 127.0.0.1:51820. WG client config (wg0-tcp.conf)
  # points at 127.0.0.1:51821 so WG packets get wrapped automatically.
  systemd.user.services.wstunnel-client = {
    Unit = {
      Description = "WireGuard-over-TCP/443 fallback (wstunnel client → ${wsEndpoint})";
      Documentation = [ "https://github.com/erebe/wstunnel" ];
      After  = [ "network-online.target" ];
      Wants  = [ "network-online.target" ];
    };
    Service = {
      Type = "exec";
      # Pre-flight: make sure the secret file is present (sops-decrypted).
      ExecStartPre = pkgs.writeShellScript "wstunnel-precheck" ''
        if [ ! -r "${secretFile}" ]; then
          echo "[wstunnel] ERROR: ${secretFile} not found." >&2
          echo "[wstunnel] sops-decrypt the WSTUNNEL_PATH_PREFIX secret first." >&2
          exit 1
        fi
      '';
      ExecStart = pkgs.writeShellScript "wstunnel-client-start" ''
        set -eu
        PATH_PREFIX="$(cat "${secretFile}")"
        exec ${wstunnelBin} client \
          --local-to-remote 'udp://${toString localUdp}:127.0.0.1:${toString remoteWg}' \
          --http-upgrade-path-prefix "$PATH_PREFIX" \
          '${wsEndpoint}'
      '';
      Restart    = "on-failure";
      RestartSec = 10;
      MemoryMax  = "32M";
      CPUQuota   = "10%";
      # Hardening — wstunnel needs only outbound network + the secret file
      ProtectSystem        = "strict";
      ProtectHome          = "read-only";
      PrivateTmp           = true;
      NoNewPrivileges      = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
    Install = {
      WantedBy = [ ];   # NOT auto-started — user opts in only on hostile networks
    };
  };

  # ── wg0-tcp.conf (WG client config pointing at the local loopback) ─────
  # Activation script copies a pre-rendered conf into ~/.config/wireguard/.
  # The actual private key + peer pubkey lives in the existing wg0.conf —
  # this is just a duplicate Endpoint variant. User runs:
  #     sudo cp ~/.config/wireguard/wg0-tcp.conf /etc/wireguard/wg0-tcp.conf
  #     sudo wg-quick up wg0-tcp
  # to switch transport.
  home.activation.installWg0TcpConf = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    set -eu
    mkdir -p "$(dirname '${wgTcpConf}')"

    # If wg0.conf exists (existing direct-UDP config), render a sibling
    # wg0-tcp.conf with the Endpoint pointed at the local wstunnel listener.
    SOURCE='${config.home.homeDirectory}/.config/wireguard/wg0.conf'
    if [ -r "$SOURCE" ]; then
      ${pkgs.gawk}/bin/awk '
        BEGIN  { in_peer = 0 }
        /^\[Peer\]/ { in_peer = 1 }
        /^\[/      { if ($0 != "[Peer]") in_peer = 0 }
        in_peer && /^Endpoint[[:space:]]*=/ { print "Endpoint = 127.0.0.1:${toString localUdp}"; next }
        { print }
      ' "$SOURCE" > '${wgTcpConf}.tmp'
      mv '${wgTcpConf}.tmp' '${wgTcpConf}'
      chmod 600 '${wgTcpConf}'
      echo "[wireguard-wstunnel] rendered ${wgTcpConf} (Endpoint=127.0.0.1:${toString localUdp})"
    else
      echo "[wireguard-wstunnel] $SOURCE not found — skipping wg0-tcp.conf render"
    fi
  '';

  # ── Helper script: toggle direct ↔ tunnel mode in one command ──────────
  # Usage: wg-tcp [up|down|status]
  home.file.".local/bin/wg-tcp" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      # wg-tcp — toggle WireGuard-over-TCP/443 fallback (declarative wrapper)
      set -eu
      cmd="''${1:-status}"
      case "$cmd" in
        up)
          echo "[wg-tcp] starting wstunnel-client + bringing wg0-tcp up"
          ${pkgs.systemd}/bin/systemctl --user start wstunnel-client
          sleep 1
          sudo ${pkgs.wireguard-tools}/bin/wg-quick up wg0-tcp || true
          echo "[wg-tcp] tunnel via TCP/443 active"
          ;;
        down)
          echo "[wg-tcp] tearing down wg0-tcp + wstunnel-client"
          sudo ${pkgs.wireguard-tools}/bin/wg-quick down wg0-tcp || true
          ${pkgs.systemd}/bin/systemctl --user stop wstunnel-client
          ;;
        status)
          echo "── wstunnel-client systemd unit:"
          ${pkgs.systemd}/bin/systemctl --user status wstunnel-client --no-pager 2>&1 | head -10
          echo "── wg interfaces up:"
          sudo ${pkgs.wireguard-tools}/bin/wg show interfaces 2>/dev/null || echo "(none)"
          ;;
        *)
          echo "Usage: wg-tcp [up|down|status]"
          exit 1
          ;;
      esac
    '';
  };
}
