# ai/claude-superset.nix — `claude-superset`: route the local Claude Code CLI
# through the claude-superset-api Headroom proxy (token compression) over
# WireGuard, with a health-check fallback to direct Anthropic when the proxy is
# unreachable. Endpoints are data-driven from ./claude-superset.json (no inlined
# hosts/ports). The proxy is transparent (compress → forward to Anthropic with
# the client's own creds), so interactive multi-turn / tool use is preserved.
#
# Desktop analog of termux's `claude-malloc` launch wrapper — here we wrap plain
# `claude` (the desktop has no Android isolation wrapper to chain).
{ config, pkgs, lib, ... }:
let
  ep = builtins.fromJSON (builtins.readFile ./claude-superset.json);
  claude-superset = pkgs.writeShellScriptBin "claude-superset" ''
    set -u
    URL="''${CLAUDE_SUPERSET_URL:-${ep.proxy}}"
    if ${pkgs.curl}/bin/curl -fsS --max-time 2 "''${URL%/}/readyz" >/dev/null 2>&1; then
      export ANTHROPIC_BASE_URL="$URL"
      echo "[claude-superset] via superset proxy → $URL (Headroom compression ON)" >&2
    else
      echo "[claude-superset] proxy unreachable ($URL) — direct to Anthropic, no compression" >&2
    fi
    # Plugin status line (data-driven; mirrors the statusline PL[...] segment).
    pl=$(${pkgs.bash}/bin/bash "$HOME/.claude/claude-plugins-status.sh" --format plain 2>/dev/null)
    [ -n "$pl" ] && echo "[claude-superset] plugins: $pl" >&2
    exec claude "$@"
  '';

  # TUI helper/dashboard — endpoints injected from the same JSON (data-driven),
  # CAS_LAUNCH=claude (desktop has no Android isolation wrapper to chain).
  claude-superset-tui = pkgs.writeShellScriptBin "claude-superset-tui" ''
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
    exec ${pkgs.nodejs}/bin/node ${./claude-superset-tui.mjs} "$@"
  '';

  # Desktop tray (KDE Plasma 6 / SNI via yad) — live savings in the tooltip,
  # menu to open the dashboard or launch the TUI. Desktop-only (no tray on
  # termux). Autostarted by the systemd user service below.
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
      --menu="Dashboard!${pkgs.xdg-utils}/bin/xdg-open $DASH|Helper!${pkgs.kdePackages.konsole}/bin/konsole -e claude-superset-tui|Quit!quit"
  '';
in {
  home.packages = [ claude-superset claude-superset-tui claude-superset-tray ];

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
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
