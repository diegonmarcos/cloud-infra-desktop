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
    # ── Flags: mode / model / effort (parsed first) ────────────────────
    # --auto (default): pass --dangerously-skip-permissions to claude.
    # --plan / --interactive: recorded for display; no extra CLI flags.
    # --model <id>: sets ANTHROPIC_MODEL. --effort <lvl>: CLAUDE_EFFORT.
    CC_EXTRA_FLAGS=""
    while :; do
      case "''${1:-}" in
        --auto)        CC_EXTRA_FLAGS="--dangerously-skip-permissions"; shift ;;
        --plan)        shift ;;
        --interactive) shift ;;
        --model)       shift; [ -n "''${1:-}" ] && export ANTHROPIC_MODEL="$1"; shift ;;
        --effort)      shift; export CLAUDE_EFFORT="''${1:-high}"; shift ;;
        *) break ;;
      esac
    done

    # help: plain-text usage + live status (agents, plugins, sessions).
    if [ "''${1:-}" = "help" ]; then
      cat ${./claude-superset-help.txt}
      printf '\nMODEL ACTIVE\n  ANTHROPIC_MODEL=%s  CLAUDE_EFFORT=%s\n' \
        "''${ANTHROPIC_MODEL:-<unset>}" "''${CLAUDE_EFFORT:-<unset>}"
      printf '\nAGENTS\n'
      _ag_dir="$HOME/.claude/agents"; _ag_c=0
      if [ -d "$_ag_dir" ]; then
        for _f in "$_ag_dir"/*.md; do
          [ -f "$_f" ] || continue
          _n="''${_f##*/}"; _n="''${_n%.md}"
          case "$_n" in README*|readme*) continue ;; esac
          printf '  %s\n' "$_n"; _ag_c=$((_ag_c+1))
        done
        [ "$_ag_c" -eq 0 ] && printf '  (none configured)\n'
      else
        printf '  (no agents dir)\n'
      fi
      printf '\nSTATUS LINE\n  '
      bash "$HOME/.claude/claude-plugins-status.sh" --format plain 2>/dev/null || true
      printf '\n'
      _pdir="$HOME/.claude/projects"
      printf '\nSESSIONS (last 48h — unique projects)\n'
      if [ -d "$_pdir" ]; then
        find "$_pdir" -name "*.jsonl" -mmin -2880 2>/dev/null \
          | while IFS= read -r _f; do
              _dir="''${_f%/*}"; printf '%s\n' "''${_dir##*/}"
            done | sort -u | head -20 \
          | while IFS= read -r _n; do printf '  %s\n' "$_n"; done
      fi
      printf '\nSESSIONS (last 5 by time)\n'
      if [ -d "$_pdir" ]; then
        _files=$(find "$_pdir" -name "*.jsonl" 2>/dev/null | tr '\n' ' ')
        if [ -n "$_files" ]; then
          ls -t $_files 2>/dev/null | head -5 \
            | while IFS= read -r _f; do
                _id="''${_f##*/}"; _id="''${_id%.jsonl}"
                _dir="''${_f%/*}"; _proj="''${_dir##*/}"
                printf '  %s  %s\n' "$_id" "$_proj"
              done
        fi
      fi
      exit 0
    fi

    # setup: ensure `claude` is installed WITHOUT npm (native installer +
    # deps-solver, platform-aware: nix/termux declarative, deb/other native,
    # `setup --shell` = ephemeral nix-shell). Data-driven from the JSON.
    if [ "''${1:-}" = "setup" ]; then
      shift
      export CAS_SETUP_URL="${ep.setup.installer_url or "https://claude.ai/install.sh"}"
      export CAS_SETUP_CHANNEL="${ep.setup.channel or "stable"}"
      export CAS_SETUP_PKG="${ep.setup.rescue_pkg or "@anthropic-ai/claude-code"}"
      exec ${pkgs.bash}/bin/bash ${./claude-superset-setup.sh} "$@"
    fi

    # --help / -h / h: interactive status dashboard — probes every face, all
    # MCPs, plugins (Headroom + Ponytail), and direct Anthropic fallback.
    if [ "''${1:-}" = "--help" ] || [ "''${1:-}" = "-h" ] || [ "''${1:-}" = "h" ]; then
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
      export CAS_MESH='${builtins.toJSON (ep.mesh or {})}'
      export CAS_PUBLIC='${builtins.toJSON (ep.public or {})}'
      export CAS_IMAGE="${ep.image or ""}"
      export CAS_PING="${pkgs.iputils}/bin/ping" CAS_DF="${pkgs.coreutils}/bin/df" CAS_GIT="${pkgs.git}/bin/git"
      exec ${pkgs.nodejs}/bin/node ${./claude-superset-tui.mjs}
    fi

    # Face: local | remote | claude (default: remote). `local` runs the same
    # container on THIS host via docker compose; `remote` is the oci-apps proxy
    # over WG; `claude` bypasses everything (no proxy, no session engine, no
    # plugin munging) and runs a plain claude.
    # `claude` sets a PLAIN flag (no proxy/plugins) but still flows through the
    # restore dispatch below, so `claude-superset claude restore N` works —
    # restore just reopens sessions via `claude --resume`, proxy-independent.
    MODE="remote"; PLAIN=0
    case "''${1:-}" in
      claude)       MODE="claude"; PLAIN=1; shift ;;
      local|remote) MODE="$1"; shift ;;
    esac
    # Face → statusline (PL[M:{L|R|C} …]); read by claude-plugins-status.sh.
    export CLAUDE_SUPERSET_MODE="$MODE"

    # Plugin toggles (any order, before the session action):
    #   headroom on|off       — on = route via the compression proxy (sets
    #                           ANTHROPIC_BASE_URL, which the Headroom plugin
    #                           detects); off = direct to Anthropic, no compression.
    #   ponytail on|off|lite|full|ultra — sets PONYTAIL_DEFAULT_MODE, read by the
    #                           ponytail SessionStart hook.
    #   rtk on|off            — RTK (Rust Token Killer): strips CLI/test noise
    #                           BEFORE Headroom. Sets RTK_ENABLED for the proxy.
    #   caveman on|off        — Caveman: linguistic/conversational compression.
    #                           Sets CAVEMAN_ENABLED for the proxy.
    # Compression plugins default ON (like the others); plain `claude` face stays
    # bypassed. The Headroom proxy honours these signals for its pre/post stages.
    [ "$MODE" = "claude" ] || { export RTK_ENABLED=1 CAVEMAN_ENABLED=1; }
    HEADROOM="on"
    while :; do
      case "''${1:-}" in
        headroom) HEADROOM="''${2:-on}"; shift 2 || shift ;;
        ponytail)
          case "''${2:-on}" in
            on)              export PONYTAIL_DEFAULT_MODE="full" ;;
            off)             export PONYTAIL_DEFAULT_MODE="off" ;;
            lite|full|ultra) export PONYTAIL_DEFAULT_MODE="''${2}" ;;
            *) echo "[claude-superset] ponytail: on|off|lite|full|ultra" >&2; exit 2 ;;
          esac
          shift 2 || shift ;;
        rtk)     case "''${2:-on}" in on) export RTK_ENABLED=1 ;; off) unset RTK_ENABLED ;; *) echo "[claude-superset] rtk: on|off" >&2; exit 2 ;; esac; shift 2 || shift ;;
        caveman) case "''${2:-on}" in on) export CAVEMAN_ENABLED=1 ;; off) unset CAVEMAN_ENABLED ;; *) echo "[claude-superset] caveman: on|off" >&2; exit 2 ;; esac; shift 2 || shift ;;
        *) break ;;
      esac
    done

    # Session engine env (data-driven; device id = hostname unless JSON overrides).
    export CAS_API="${ep.api}" CAS_SELF="claude-superset" CAS_FACE="$MODE"
    # ''${VAR-default}: a pre-set (even empty) CAS_KONSOLE/CAS_TMUX survives —
    # lets tests disable tab-spawning without the wrapper clobbering it.
    export CAS_KONSOLE="''${CAS_KONSOLE-${pkgs.kdePackages.konsole}/bin/konsole}"
    export CAS_TMUX="''${CAS_TMUX-${pkgs.tmux}/bin/tmux}"
    ${lib.optionalString ((ep.device or "") != "") ''export CAS_DEVICE="${ep.device}"''}
    CAS_DEVICE="''${CAS_DEVICE:-}"   # empty => engine falls back to os.hostname()
    ENGINE="${pkgs.nodejs}/bin/node ${./claude-superset-restore.mjs}"
    KEEP="${toString (ep.sync_keep or 20)}"

    # Resume tabs (spawned by a restore fan-out) carry `--resume` — they must
    # ATTACH to the already-running shared proxy, never manage the container.
    case " $* " in *" --resume "*) IS_RESUME=1 ;; *) IS_RESUME=0 ;; esac

    # local face uses exactly ONE container (like remote uses one VM). Bring it
    # up ONCE here — in the parent, BEFORE any restore fan-out — so N restored
    # tabs reuse it instead of each running `docker compose up`. Skipped for
    # resume tabs (they attach below) and when headroom is off.
    if [ "$MODE" = "local" ] && [ "$HEADROOM" = "on" ] && [ "$IS_RESUME" = "0" ]; then
      case "''${1:-}" in
        down|stop) exec docker compose -p claude-superset-local -f ${localCompose} down ;;
      esac
      echo "[claude-superset] local — ensuring the ONE container is up (${lo.container_name})" >&2
      docker compose -p claude-superset-local -f ${localCompose} up -d || {
        echo "[claude-superset] docker compose up failed — is dockerd running?" >&2; exit 1; }
      for _ in $(seq 1 45); do
        ${pkgs.curl}/bin/curl -fsS --max-time 2 "${lo.proxy}/readyz" >/dev/null 2>&1 && break
        sleep 2
      done
    fi

    # Session action (default: fresh = passthrough to claude).
    #   sync                              push last KEEP local sessions to the hub
    #   restore <X> | restore-hours <Y>   reopen this device's recent sessions
    #   restore <device|all> <X>          pull+reopen another device's sessions
    # Restore fans out one tab/window per session (konsole → tmux → plain).
    case "''${1:-}" in
      sync) exec $ENGINE sync "$CAS_DEVICE" "$KEEP" ;;
      restore|restore-hours)
        sel=count; [ "$1" = "restore-hours" ] && sel=hours; shift
        devsel="local"; a="''${1:-}"; b="''${2:-}"
        case "$a" in
          ""|*[!0-9]*) devsel="$a"; val="$b" ;;   # non-numeric => device selector
          *)           val="$a" ;;                 # numeric     => this device
        esac
        case "$val" in ""|*[!0-9]*)
          echo "[claude-superset] restore needs a positive number" >&2; exit 2 ;;
        esac
        exec $ENGINE launch "$MODE" "$devsel" "$sel" "$val" ;;
      fresh) shift ;;
    esac

    # Plain `claude` face: no proxy, no plugins, no auto-sync. Any restore action
    # was already dispatched above; a bare `claude-superset claude [args…]` (incl.
    # `--resume <id>` from a restored tab) execs plain claude here.
    if [ "$PLAIN" = "1" ]; then
      exec claude $CC_EXTRA_FLAGS "$@"
    fi

    # Wire ANTHROPIC_BASE_URL by a SHORT probe (no bring-up here — the local
    # container was already ensured once above; resume tabs just attach). Same
    # shape as remote: point at a URL, fall back to direct if unreachable. This
    # is what makes N restored `local` tabs share ONE container.
    if [ "$HEADROOM" = "on" ]; then
      if [ "$MODE" = "local" ]; then URL="${lo.proxy}"; else URL="''${CLAUDE_SUPERSET_URL:-${ep.proxy}}"; fi
      if ${pkgs.curl}/bin/curl -fsS --max-time 2 "''${URL%/}/readyz" >/dev/null 2>&1; then
        export ANTHROPIC_BASE_URL="$URL"
        echo "[claude-superset] via $MODE proxy → $URL (Headroom compression ON)" >&2
      else
        [ "$MODE" = "local" ] && echo "[claude-superset] local proxy not ready — first run: docker exec -it ${lo.container_name} claude" >&2
        echo "[claude-superset] proxy unreachable ($URL) — direct to Anthropic, no compression" >&2
      fi
    else
      echo "[claude-superset] Headroom OFF — direct to Anthropic (no compression)" >&2
    fi

    # Auto-sync recent sessions to the hub (best-effort, background) unless this
    # is a resumed session (restored tabs would otherwise re-push on every open).
    case " $* " in
      *" --resume "*) : ;;
      *) ( $ENGINE sync "$CAS_DEVICE" "$KEEP" >/dev/null 2>&1 & ) ;;
    esac

    # Plugin status line (data-driven; mirrors the statusline PL[...] segment).
    pl=$(${pkgs.bash}/bin/bash "$HOME/.claude/claude-plugins-status.sh" --format plain 2>/dev/null)
    [ -n "$pl" ] && echo "[claude-superset] plugins: $pl" >&2
    exec claude $CC_EXTRA_FLAGS "$@"
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
  # my-ai: future replacement alias — shares the claude-superset script via exec.
  my-ai = pkgs.writeShellScriptBin "my-ai" ''
    exec claude-superset "$@"
  '';
in {
  home.packages = [ claude-superset claude-superset-tray my-ai ];

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
