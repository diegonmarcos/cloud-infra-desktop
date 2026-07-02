# ai/claude-superset.nix — `claude-superset`: route the local Claude Code CLI
# through the claude-superset-api Headroom proxy (token compression) over
# WireGuard, with a health-check fallback to direct Anthropic when the proxy is
# unreachable. Endpoints are data-driven from ./claude-superset.json (no inlined
# hosts/ports). The proxy is transparent (compress → forward to Anthropic with
# the client's own creds), so interactive multi-turn / tool use is preserved.
#
# `claude-superset [remote] …`  → route through the oci-apps proxy over WG
#   (current behaviour; default when no subcommand is given).
# `claude-superset local …`     → run the SAME container on THIS host via docker
#   compose (on-demand), published to 127.0.0.1 only, and route through it.
#   `claude-superset local down` tears it down. First run needs a one-time
#   `docker exec -it claude-superset-api-local claude` login.
#
# `claude-superset --help` opens an interactive status dashboard (probes all
# faces, MCPs, plugins including Ponytail, and the direct Anthropic fallback).
# The dashboard logic lives in ./claude-superset-tui.mjs — not exposed as a
# separate binary.
{ config, pkgs, lib, ... }:
let
  ep = builtins.fromJSON (builtins.readFile ./claude-superset.json);
  lo = ep.local;

  # Local compose file — same container as oci-apps, but published to 127.0.0.1
  # only (never the public NIC) and bound to 0.0.0.0 inside the bridge network.
  # Data-driven from ./claude-superset.json `local`. No env_file: local mode is
  # a compute fallback; the Claude login lives in the named volume (one-time
  # `docker exec -it ${lo.container_name} claude`). The HTTP MCP bearer is not
  # wired here — the remote face carries MCPs.
  # ponytail: no bearer/MCP env_file locally, add from vault signed-jwt if the
  # local face ever needs the HTTP MCP servers.
  localCompose = pkgs.writeText "claude-superset-local.yaml" (builtins.toJSON {
    services.claude-superset-api = {
      image = lo.image;
      container_name = lo.container_name;
      pull_policy = "always";
      init = true;
      ports = [
        "127.0.0.1:${toString lo.ports.app}:${toString lo.ports.app}"
        "127.0.0.1:${toString lo.ports.ollama}:${toString lo.ports.ollama}"
        "127.0.0.1:${toString lo.ports.headroom}:${toString lo.ports.headroom}"
        "127.0.0.1:${toString lo.ports.proxy}:${toString lo.ports.proxy}"
      ];
      environment = {
        HOME = "/home/appuser";
        BRIDGE_PORT = toString lo.ports.app;
        BRIDGE_BIND = "0.0.0.0";
        BRIDGE_OLLAMA_PORT = toString lo.ports.ollama;
        BRIDGE_OLLAMA_BIND = "0.0.0.0";
        BRIDGE_DEFAULT_MODEL = lo.model;
        BRIDGE_MAX_CONCURRENCY = toString lo.max_concurrency;
        BRIDGE_CALL_TIMEOUT_MS = toString lo.call_timeout_ms;
        HEADROOM_ENABLED = "1";
        HEADROOM_HOST = "0.0.0.0";
        HEADROOM_BIND = "0.0.0.0";
        HEADROOM_PORT = toString lo.ports.headroom;
        HEADROOM_SAVINGS_PROFILE = lo.savings_profile;
        HEADROOM_MIN_TOKENS = toString lo.min_tokens_to_compress;
        HEADROOM_PROXY_ENABLED = "1";
        HEADROOM_PROXY_PORT = toString lo.ports.proxy;
        HEADROOM_PROXY_BIND = "0.0.0.0";
        HEADROOM_PROXY_BACKEND = "anthropic";
        HEADROOM_WORKSPACE_DIR = "/home/appuser/.headroom";
      };
      volumes = [ "${lo.volume}:/home/appuser" ];
    };
    volumes."${lo.volume}" = { name = lo.volume; };
  });

  claude-superset = pkgs.writeShellScriptBin "claude-superset" ''
    set -u
    # --help / -h: interactive status dashboard — probes every face, all MCPs,
    # plugins (Headroom + Ponytail), and direct Anthropic fallback.
    if [ "''${1:-}" = "--help" ] || [ "''${1:-}" = "-h" ]; then
      export CAS_PROXY="${ep.proxy}" CAS_API="${ep.api}" CAS_OLLAMA="${ep.ollama}"
      export CAS_DASHBOARD="${ep.dashboard}" CAS_LAUNCH="claude"
      export CAS_COMPRESS="''${CAS_DASHBOARD%/dashboard}"
      export CAS_ANTHROPIC="${ep.anthropic}"
      export CAS_MCP_C3_INFRA="${ep.mcps.c3_infra}"
      export CAS_MCP_C3_SVC="${ep.mcps.c3_svc}"
      export CAS_MCP_MATTERMOST="${ep.mcps.mattermost}"
      export CAS_MCP_MAIL="${ep.mcps.mail}"
      export CAS_MCP_GWS="${ep.mcps.gws}"
      export CAS_MCP_GP="${ep.mcps.gp}"
      export CAS_PLUGINS_SCRIPT="$HOME/.claude/claude-plugins-status.sh"
      exec ${pkgs.nodejs}/bin/node ${./claude-superset-tui.mjs}
    fi

    # Subcommand: local | remote (default: remote). `local` runs the same
    # container on THIS host via docker compose (on-demand); `remote` is the
    # oci-apps proxy over WG with a direct-Anthropic fallback.
    MODE="remote"
    case "''${1:-}" in
      local|remote) MODE="$1"; shift ;;
    esac

    if [ "$MODE" = "local" ]; then
      # `local down` / `local stop` tears the container down.
      case "''${1:-}" in
        down|stop)
          exec docker compose -p claude-superset-local -f ${localCompose} down ;;
      esac
      echo "[claude-superset] local mode — ensuring container up (${lo.container_name})" >&2
      docker compose -p claude-superset-local -f ${localCompose} up -d || {
        echo "[claude-superset] docker compose up failed — is dockerd running?" >&2; exit 1; }
      URL="${lo.proxy}"
      # Wait for the local Headroom proxy to answer (image pull + start_period).
      for _ in $(seq 1 60); do
        ${pkgs.curl}/bin/curl -fsS --max-time 2 "''${URL%/}/readyz" >/dev/null 2>&1 && break
        sleep 2
      done
      if ${pkgs.curl}/bin/curl -fsS --max-time 2 "''${URL%/}/readyz" >/dev/null 2>&1; then
        export ANTHROPIC_BASE_URL="$URL"
        echo "[claude-superset] via LOCAL proxy → $URL (Headroom compression ON)" >&2
      else
        echo "[claude-superset] local proxy not ready — first run needs a login:" >&2
        echo "    docker exec -it ${lo.container_name} claude" >&2
        echo "[claude-superset] continuing direct to Anthropic, no compression" >&2
      fi
    else
      URL="''${CLAUDE_SUPERSET_URL:-${ep.proxy}}"
      if ${pkgs.curl}/bin/curl -fsS --max-time 2 "''${URL%/}/readyz" >/dev/null 2>&1; then
        export ANTHROPIC_BASE_URL="$URL"
        echo "[claude-superset] via superset proxy → $URL (Headroom compression ON)" >&2
      else
        echo "[claude-superset] proxy unreachable ($URL) — direct to Anthropic, no compression" >&2
      fi
    fi
    # Plugin status line (data-driven; mirrors the statusline PL[...] segment).
    pl=$(${pkgs.bash}/bin/bash "$HOME/.claude/claude-plugins-status.sh" --format plain 2>/dev/null)
    [ -n "$pl" ] && echo "[claude-superset] plugins: $pl" >&2
    exec claude "$@"
  '';

  # Desktop tray (KDE Plasma 6 / SNI via yad) — live savings in the tooltip,
  # menu to open the dashboard or launch claude via the proxy. Desktop-only.
  # Autostarted by the systemd user service below.
  claude-superset-tray = pkgs.writeShellScriptBin "claude-superset-tray" ''
    set -u
    DASH="${ep.dashboard}"
    ROOT="''${DASH%/dashboard}"
    refresh() {
      while true; do
        saved=$(${pkgs.curl}/bin/curl -fsS --max-time 2 "$ROOT/stats" 2>/dev/null \
          | ${pkgs.nodejs}/bin/node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(Number(j.tokens_saved||0).toLocaleString()+" tok ("+((j.lifetime_ratio||0)*100).toFixed(0)+"%)")}catch{process.stdout.write("offline")}})' 2>/dev/null || echo "offline")
        printf 'tooltip:claude-superset — %s saved\n' "$saved"
        sleep 30
      done
    }
    refresh | ${pkgs.yad}/bin/yad --notification --listen \
      --image=utilities-terminal --text="claude-superset" \
      --menu="Dashboard!${pkgs.xdg-utils}/bin/xdg-open $DASH|Status!${pkgs.kdePackages.konsole}/bin/konsole -e claude-superset --help|Quit!quit"
  '';
in {
  home.packages = [ claude-superset claude-superset-tray ];

  # Autostart the tray with the graphical session (manual-recovery friendly:
  # Restart is intentionally NOT set — matches the fleet no-auto-restart rule).
  systemd.user.services.claude-superset-tray = {
    Unit = {
      Description = "claude-superset system-tray helper";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${claude-superset-tray}/bin/claude-superset-tray";
    };
    # NO autostart — electron tray must not be launched by systemd at login.
    # Start manually if wanted: `systemctl --user start claude-superset-tray`.
    Install.WantedBy = [ ];
  };
}
