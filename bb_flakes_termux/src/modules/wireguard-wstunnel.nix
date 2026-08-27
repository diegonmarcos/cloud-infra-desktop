# Cloud Network — WireGuard-over-TCP/443 fallback (wstunnel client) — Termux
#
# Termux/nix-on-droid sibling of ~/git/cloud-infra-desktop/ba_flakes_desktop/src/modules/
# wireguard-wstunnel.nix. Same role: tunnel UDP/127.0.0.1:51821 → WSS over
# TCP/443 to the wstunnel-server on gcp-proxy.
#
# Termux differences vs desktop:
#   • no systemd-user — wstunnel runs as a foreground process via the
#     `wg-tcp` helper (use `termux-wake-lock` to keep it alive when the
#     screen sleeps). The helper backgrounds wstunnel and writes a PID file.
#   • no wg-quick — WireGuard on Android is managed by the Termux:WireGuard
#     app (or `wg` userspace tool). The helper does NOT toggle the WG
#     interface itself; it only starts/stops the wstunnel transport. The
#     user switches WG profiles on the phone (wg0 vs wg0-tcp) manually.
#   • activation renders wg0-tcp.conf into ~/.config/wireguard/ exactly as on
#     desktop, so the user can import it into Termux:WireGuard.
#
# Source of truth (data-driven, fire-rule 4 + 6):
#   ~/git/cloud-infra/a_solutions/bb-net_wireguard-mesh-ws-tunnel/build.json
#     • .domain → vpnDomain (the WSS server hostname)
#
# Secrets:
#   WSTUNNEL_PATH_PREFIX is read from $HOME/.config/wireguard/.wstunnel-secret
#   at run time. The user copies the value into that file with `chmod 600`
#   (no sops on Android by default).
#
# Decommission: identical to desktop — remove this module + the
# `wg-tcp` helper and the wg0-tcp.conf in ~/.config/wireguard/.

{ config, lib, pkgs, wstunnel, ... }:

let
  # ── Data sources (declarative cross-references, no inlined values) ──────
  # Path resolution: termux runs out of $HOME/storage/shared/git/<repo>/...
  # We try the canonical relative path first; if not present, fall back to
  # the absolute storage path that the termux flake uses everywhere else.
  cloudRel  = ../../../../cloud/a_solutions/bb-net_wireguard-mesh-ws-tunnel/build.json;
  wsTunnelBuildJson =
    if builtins.pathExists cloudRel
    then builtins.fromJSON (builtins.readFile cloudRel)
    else null;

  vpnDomain   = if wsTunnelBuildJson != null then wsTunnelBuildJson.domain else "vpn.diegonmarcos.com";
  wsEndpoint  = "wss://${vpnDomain}:443";
  localUdp    = 51821;            # local loopback port wstunnel-client listens on
  remoteWg    = 51820;            # kernel WG listener on gcp-proxy
  secretFile  = "${config.home.homeDirectory}/.config/wireguard/.wstunnel-secret";
  pidFile     = "${config.home.homeDirectory}/.config/wireguard/.wstunnel.pid";
  logFile     = "${config.home.homeDirectory}/.config/wireguard/.wstunnel.log";
  wgTcpConf   = "${config.home.homeDirectory}/.config/wireguard/wg0-tcp.conf";
  # wstunnel comes via _module.args (flake.nix → pkgsUnstable.wstunnel, Rust 7.x).
  # The pinned nixos-24.05 'pkgs.wstunnel' is Haskell 0.5.x and pulls a broken dep.
  wstunnelBin = "${wstunnel}/bin/wstunnel";
  wg0Conf     = "${config.home.homeDirectory}/.config/wireguard/wg0.conf";

  # ── Runtime JSON (fire-rule 4 + 6: no values baked in by interpolation
  # inside the .sh bodies — the scripts read all of this via jq at RUNTIME).
  # Deployed to ${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/wireguard-wstunnel.json
  wstunnelRuntimeJson = builtins.toJSON {
    local_udp_port = localUdp;
    remote_wg_port = remoteWg;
    ws_endpoint = wsEndpoint;
    secret_file = secretFile;
    pid_file = pidFile;
    log_file = logFile;
    wg0_conf = wg0Conf;
    wg_tcp_conf = wgTcpConf;
  };

  wgTcpPkg = pkgs.writeShellApplication {
    name = "wg-tcp";
    runtimeInputs = [ pkgs.jq pkgs.gawk pkgs.procps ];
    runtimeEnv = {
      WG_TCP_WSTUNNEL_BIN = wstunnelBin;
    };
    text = builtins.readFile ./wireguard-wstunnel.sh;
  };

  wgTcpRenderPkg = pkgs.writeShellApplication {
    name = "wireguard-wstunnel-render";
    # util-linux supplies `logger` (fail-loud path).
    runtimeInputs = [ pkgs.jq pkgs.gawk pkgs.util-linux ];
    text = builtins.readFile ./wireguard-wstunnel-render.sh;
  };
in
{
  # ── Package: wstunnel binary (Rust, ~10 MB RSS when active) ────────────
  home.packages = [ wstunnel ];

  # ── Helper script: exposed at the same path as before (~/.local/bin/wg-tcp)
  # so callers/tests that reference this exact path keep working. The real
  # implementation is now the writeShellApplication-wrapped wgTcpPkg above.
  home.file.".local/bin/wg-tcp" = {
    source = "${wgTcpPkg}/bin/wg-tcp";
  };

  # ── Runtime JSON deploy (Home Manager: xdg.configFile, not environment.etc) ──
  xdg.configFile."cloud-data/wireguard-wstunnel.json".text = wstunnelRuntimeJson;

  # ── wg0-tcp.conf (WG client config pointing at the local loopback) ─────
  # Identical render rule as desktop — only the Endpoint line is rewritten.
  # Termux WG is managed by the Termux:WireGuard app, so the user imports
  # this file as a separate profile and toggles between wg0 and wg0-tcp.
  home.activation.installWg0TcpConf = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    ${wgTcpRenderPkg}/bin/wireguard-wstunnel-render
  '';
}
