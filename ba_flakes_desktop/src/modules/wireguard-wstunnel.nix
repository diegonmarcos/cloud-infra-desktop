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

{ config, lib, pkgs, inputs, ... }:

let
  # ── Data sources (declarative cross-references, no inlined values) ──────
  # Sourced from the `cloud-repo` flake input (pinned github fetch of
  # diegonmarcos/cloud) — always fetchable in fresh clones / CI / sandboxed
  # evals. Local hacking? Override at build time:
  #   --override-input cloud-repo path:/home/$USER/git/cloud
  wsTunnelBuildJson =
    let path = "${inputs.cloud-repo}/a_solutions/bb-net_wireguard-mesh-ws-tunnel/build.json";
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
          --restrict-http-upgrade-path-prefix "$PATH_PREFIX" \
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

  # ── wg0-tcp.conf + NetworkManager auto-import (KDE applet visible) ─────
  # Two-step activation:
  #   1. Render ~/.config/wireguard/wg0-tcp.conf from existing wg0.conf
  #      (rewrite Endpoint → 127.0.0.1:${localUdp})
  #   2. Import into NetworkManager so the wg0-tcp profile appears in the
  #      KDE Plasma network applet alongside wg0 — idempotent (skip if a
  #      connection named "wg0-tcp" already exists).
  #
  # `nmcli connection import` needs root; we go through `sudo -n` so the
  # activation succeeds when the user has passwordless sudo for nmcli (the
  # standard NixOS surface-plasma profile). If sudo prompts, the import is
  # skipped with a one-line hint — the wg-tcp helper still works.
  home.activation.installWg0TcpConf = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    set -eu
    mkdir -p "$(dirname '${wgTcpConf}')"

    # ── (1) Render wg0-tcp.conf ───────────────────────────────────────
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
      exit 0
    fi

    # ── (2) NetworkManager import (so KDE applet sees wg0-tcp) ────────
    # Skip when nmcli is unavailable (server/CI builds).
    if ! command -v ${pkgs.networkmanager}/bin/nmcli >/dev/null 2>&1; then
      exit 0
    fi
    NMCLI=${pkgs.networkmanager}/bin/nmcli

    # If a profile named "wg0-tcp" already exists, leave it alone (user
    # may have edited it). Idempotent re-runs are fast no-ops.
    if $NMCLI -t -f NAME connection show 2>/dev/null | grep -qx 'wg0-tcp'; then
      echo "[wireguard-wstunnel] NetworkManager profile 'wg0-tcp' already present — skipping import"
      exit 0
    fi

    # Import requires root (system-connections live in /etc/NetworkManager/).
    # Try passwordless sudo; if not allowed, surface a one-line hint and exit
    # cleanly so home-manager activation doesn't fail.
    if sudo -n $NMCLI connection import type wireguard file '${wgTcpConf}' >/dev/null 2>&1; then
      echo "[wireguard-wstunnel] imported wg0-tcp into NetworkManager — visible in KDE applet"
      sudo -n $NMCLI connection modify wg0-tcp connection.autoconnect no >/dev/null 2>&1 || true
    else
      echo "[wireguard-wstunnel] NM import needs root — run once manually:"
      echo "    sudo nmcli connection import type wireguard file ${wgTcpConf}"
      echo "    sudo nmcli connection modify wg0-tcp connection.autoconnect no"
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
