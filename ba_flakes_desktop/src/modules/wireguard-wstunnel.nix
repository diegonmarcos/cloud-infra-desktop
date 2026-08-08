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
  wg0Conf     = "${config.home.homeDirectory}/.config/wireguard/wg0.conf";

  # ── Runtime JSON (fire-rule 4 + 6) ─────────────────────────────────────
  # Values still originate from the cloud build.json source of truth above;
  # only their *consumption* moved from Nix-eval-time interpolation into a
  # runtime jq read, so the extracted .sh files carry no baked-in config.
  # Deployed to ${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/wireguard-wstunnel.json
  # NOTE: secretFile is a PATH only — the WSTUNNEL_PATH_PREFIX secret itself
  # is never written to this JSON nor to the nix store; it stays sops-managed
  # on disk and is read by the unit at run time.
  wstunnelRuntimeJson = builtins.toJSON {
    local_udp_port   = localUdp;
    remote_wg_port   = remoteWg;
    ws_endpoint      = wsEndpoint;
    secret_file      = secretFile;
    wg0_conf         = wg0Conf;
    wg_tcp_conf      = wgTcpConf;
    wg_tcp_interface = "wg0-tcp";
    service_unit     = "wstunnel-client";
  };

  wgTcpPkg = pkgs.writeShellApplication {
    name = "wg-tcp";
    runtimeInputs = [ pkgs.jq ];
    runtimeEnv = {
      WG_TCP_SYSTEMCTL_BIN = "${pkgs.systemd}/bin/systemctl";
      WG_TCP_WG_QUICK_BIN  = "${pkgs.wireguard-tools}/bin/wg-quick";
      WG_TCP_WG_BIN        = "${pkgs.wireguard-tools}/bin/wg";
    };
    text = builtins.readFile ./wireguard-wstunnel.sh;
  };

  wgTcpRenderPkg = pkgs.writeShellApplication {
    name = "wireguard-wstunnel-render";
    # util-linux supplies `logger` (fail-loud path); gnugrep for `grep -qx`.
    runtimeInputs = [ pkgs.jq pkgs.gawk pkgs.gnugrep pkgs.util-linux ];
    runtimeEnv = {
      WG_RENDER_NMCLI_BIN = "${pkgs.networkmanager}/bin/nmcli";
    };
    text = builtins.readFile ./wireguard-wstunnel-render.sh;
  };
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
      ExecStartPre = pkgs.writeShellScript "wstunnel-precheck"
        (builtins.replaceStrings
          [ "@secretFile@" ]
          [ secretFile      ]
          (builtins.readFile ./scripts/wstunnel-precheck.sh));
      ExecStart = pkgs.writeShellScript "wstunnel-client-start"
        (builtins.replaceStrings
          [ "@secretFile@" "@wstunnelBin@" "@localUdp@"          "@remoteWg@"          "@wsEndpoint@" ]
          [ secretFile      wstunnelBin     (toString localUdp)   (toString remoteWg)   wsEndpoint     ]
          (builtins.readFile ./scripts/wstunnel-client-start.sh));
      Restart    = "on-failure";
      RestartSec = 10;
      # No MemoryMax (2026-08-07): a hard per-service cap is a spurious-kill
      # risk on a connectivity-critical tunnel — the global PSI watchdog
      # (aa_desk-usr.../cloud-data-system-protection.json) is the sole kill
      # authority now. CPUQuota is a throttle, not a kill, so it stays.
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
  # Subshell wrap: `exit 0` short-circuits (missing wg0.conf, no nmcli,
  # already-imported profile) must not kill the HM activation chain. Without
  # this, every activation alphabetically after `installW*` (mcpSecrets,
  # mcpNodeModulesSymlinks, lockScreenWallpaper, …) is silently skipped.
  home.activation.installWg0TcpConf = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    (
    ${wgTcpRenderPkg}/bin/wireguard-wstunnel-render
    ) || echo "[wireguard-wstunnel] subshell exited non-zero; HM chain continues"
  '';

  # ── Runtime JSON deploy (Home Manager: xdg.configFile) ─────────────────
  xdg.configFile."cloud-data/wireguard-wstunnel.json".text = wstunnelRuntimeJson;

  # ── Helper script: toggle direct ↔ tunnel mode in one command ──────────
  # Usage: wg-tcp [up|down|status]
  # Implementation lives in ./wireguard-wstunnel.sh, wrapped above as the
  # `wg-tcp` writeShellApplication; the ~/.local/bin/wg-tcp path is kept so
  # existing callers and docs are unaffected.
  home.file.".local/bin/wg-tcp".source = "${wgTcpPkg}/bin/wg-tcp";

}
