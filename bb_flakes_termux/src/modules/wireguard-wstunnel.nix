# Cloud Network — WireGuard-over-TCP/443 fallback (wstunnel client) — Termux
#
# Termux/nix-on-droid sibling of ~/git/unix/ba_flakes_desktop/src/modules/
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
#   ~/git/cloud/a_solutions/bb-net_wireguard-mesh-ws-tunnel/build.json
#     • .domain → vpnDomain (the WSS server hostname)
#
# Secrets:
#   WSTUNNEL_PATH_PREFIX is read from $HOME/.config/wireguard/.wstunnel-secret
#   at run time. The user copies the value into that file with `chmod 600`
#   (no sops on Android by default).
#
# Decommission: identical to desktop — remove this module + the
# `wg-tcp` helper and the wg0-tcp.conf in ~/.config/wireguard/.

{ config, lib, pkgs, ... }:

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
  wstunnelBin = "${pkgs.wstunnel}/bin/wstunnel";
in
{
  # ── Package: wstunnel binary (Rust, ~10 MB RSS when active) ────────────
  home.packages = with pkgs; [
    wstunnel
  ];

  # ── wg0-tcp.conf (WG client config pointing at the local loopback) ─────
  # Identical render rule as desktop — only the Endpoint line is rewritten.
  # Termux WG is managed by the Termux:WireGuard app, so the user imports
  # this file as a separate profile and toggles between wg0 and wg0-tcp.
  home.activation.installWg0TcpConf = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    set -eu
    mkdir -p "$(dirname '${wgTcpConf}')"

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

  # ── Helper script: foreground/background-toggle for wstunnel-client ────
  # Usage: wg-tcp [up|down|status]
  #   up      starts wstunnel client in the background, writes PID + log
  #   down    SIGTERM the recorded PID
  #   status  shows whether the PID is alive + tail of log
  #
  # Termux-specific: requires `termux-wake-lock` running so Android doesn't
  # kill the wstunnel process when the screen sleeps. The helper warns if
  # the lock is not held.
  home.file.".local/bin/wg-tcp" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      # wg-tcp — WireGuard-over-TCP/443 fallback (Termux foreground variant)
      set -eu
      cmd="''${1:-status}"
      PIDFILE='${pidFile}'
      LOGFILE='${logFile}'
      SECRET='${secretFile}'

      pid_alive() {
        [ -f "$PIDFILE" ] || return 1
        local p; p=$(cat "$PIDFILE" 2>/dev/null) || return 1
        [ -n "$p" ] && kill -0 "$p" 2>/dev/null
      }

      case "$cmd" in
        up)
          if pid_alive; then echo "[wg-tcp] wstunnel-client already running (pid=$(cat "$PIDFILE"))"; exit 0; fi
          if [ ! -r "$SECRET" ]; then
            echo "[wg-tcp] ERROR: $SECRET not found." >&2
            echo "[wg-tcp] Put 64-char hex (sops -d <secrets.yaml>) into that file, chmod 600." >&2
            exit 1
          fi
          PATH_PREFIX="$(cat "$SECRET")"
          : >"$LOGFILE"
          ${wstunnelBin} client \
            --local-to-remote 'udp://${toString localUdp}:127.0.0.1:${toString remoteWg}' \
            --restrict-http-upgrade-path-prefix "$PATH_PREFIX" \
            '${wsEndpoint}' >>"$LOGFILE" 2>&1 &
          echo "$!" > "$PIDFILE"
          sleep 1
          if pid_alive; then
            echo "[wg-tcp] wstunnel-client up (pid=$!) — endpoint=${wsEndpoint}"
            echo "[wg-tcp] log: $LOGFILE"
          else
            echo "[wg-tcp] FAILED to start — see $LOGFILE" >&2
            tail -5 "$LOGFILE" >&2 || true
            exit 1
          fi
          # Wake-lock advisory (Android kills bg processes without it)
          if ! pgrep -f termux-wake-lock >/dev/null 2>&1; then
            echo "[wg-tcp] WARNING: termux-wake-lock not held — Android may kill wstunnel when screen sleeps."
            echo "[wg-tcp] Run: termux-wake-lock"
          fi
          ;;
        down)
          if ! pid_alive; then echo "[wg-tcp] not running"; rm -f "$PIDFILE"; exit 0; fi
          p=$(cat "$PIDFILE")
          kill -TERM "$p" 2>/dev/null || true
          sleep 1
          if pid_alive; then kill -KILL "$p" 2>/dev/null || true; fi
          rm -f "$PIDFILE"
          echo "[wg-tcp] wstunnel-client down"
          ;;
        status)
          if pid_alive; then
            echo "[wg-tcp] UP — pid=$(cat "$PIDFILE")"
            echo "── log tail (${logFile}) ──"
            tail -5 "$LOGFILE" 2>/dev/null || echo "(no log)"
          else
            echo "[wg-tcp] DOWN"
          fi
          ;;
        *)
          echo "Usage: wg-tcp [up|down|status]"
          exit 1
          ;;
      esac
    '';
  };
}
