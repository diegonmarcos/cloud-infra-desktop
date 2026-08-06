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
# The dashboard logic lives in da_my-ai/superset/claude-superset-tui.mjs (the
# single source of truth) — not exposed as a separate binary.
{ config, pkgs, lib, inputs, ... }:
let
  my-ai = inputs.my-ai-src.packages.x86_64-linux.my-ai;

  # Config for the desktop tray — read from the unified da_my-ai SoT config.
  ep = builtins.fromJSON (builtins.readFile ../../../../da_my-ai/superset/claude-superset.json);

  # claude-superset is an ASSET OF my-ai — it ships INSIDE the my-ai package
  # (installed by da_my-ai/nix/my-ai.nix from da_my-ai/superset/). The flake
  # only pulls my-ai; it never installs the wrapper itself. This alias lets the
  # tray + desktop entries below keep referencing `${claude-superset}/bin/claude-superset`.
  claude-superset = my-ai;

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
  # NO my-ai stub here, deliberately.
  #
  # This used to be `writeShellScriptBin "my-ai" "exec claude-superset \"$@\""` as a
  # "future replacement alias". Two problems, both load-bearing:
  #
  #  1. It SHADOWED the real binary. The Rust my-ai installs to ~/.local/bin via
  #     `build.sh install`, but ~/.nix-profile/bin precedes it on PATH, so the stub
  #     always won and the real implementation could never run.
  #  2. Forwarding to claude-superset meant `my-ai usage --statusline` landed in the
  #     263MB claude binary, where --statusline is not a valid option. The status
  #     line called it every second per session: ~296MB and 0.76s to print an error.
  #     That drove /user.slice past oomd's 30% pressure limit and killed plasmashell
  #     twice on 2026-07-31.
  #
  # Leaving my-ai absent is strictly better than aliasing it: the status line reads a
  # published segment file and simply omits the row when it's missing, so an absent
  # my-ai degrades silently while a wrong one takes the desktop down.
in {
  home.packages = [
    # my-ai ships claude-superset inside it (bin/claude-superset) — no separate entry.
    claude-superset-tray
    # Pre-built Rust binary from GH Release via da_my-ai flake input.
    # Hashes auto-updated by ship-my-ai-app.yml's update-hashes job.
    my-ai
    # Headless `my-ai usage --daemon` is the unit's ExecStart, not the GUI:
    # it now grows its own ksni systray when a display is present, so the
    # GUI's webview no longer has to be paid for just to get a tray icon.
    # my-ai-gui stays a normal user-launched app (desktop entry below).
    #
    # This wrapper and the systemd.user.services.my-ai-usage unit below are a
    # deliberate MIRROR of da_my-ai/build.sh, so switch-installed and
    # home-manager-installed machines behave identically. Keep them in step.
    (pkgs.writeShellScriptBin "my-ai-usage-daemon" ''
      exec "${my-ai}/bin/my-ai" usage --daemon --interval 30
    '')
  ];

  # The producer half of the status line's usage row: one publisher for the whole
  # session, writing $XDG_RUNTIME_DIR/my-ai-usage.seg on an interval. The status
  # line only ever reads that file, so cost is decoupled from repaint frequency —
  # N sessions repainting every second cost exactly one scan per interval, not N
  # per second. The daemon grows its own ksni systray in-process when a display
  # is present (da_my-ai/cli/src/tray.rs), so this one unit both publishes and
  # shows the tray icon — no separate GUI process to keep alive.
  #
  # my-ai is now managed by the da_my-ai flake input: always present after
  # `home-manager switch`, no ConditionPathExists guard needed.
  # ONE always-running publisher per machine, and it is visible.
  #
  # my-ai-gui remains a separate, hand-launched app (desktop entry below) for
  # people who want the full Tauri window; the unit no longer runs it. It used
  # to: the wrapper preferred the GUI for its tray, which put a full webview in
  # this unit's cgroup for a job that only writes a ~39KB JSON every 30s — on
  # this 8GB box that pinned the 128M cap, was OOM-killed 251 times, and burned
  # 6min CPU in 9min wall time, then exited 0 and stayed dead (Restart was
  # on-failure), silently freezing the status line's 05h-T/05h-S rows.
  systemd.user.services.my-ai-usage = {
    Unit = {
      Description = "my-ai usage publisher + systray (5h window data for the Claude status line)";
      # The tray needs a session to attach to; without this it races the
      # compositor at login, fails soft (ksni is best-effort), and the
      # publisher keeps running headless for the session.
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "%h/.local/bin/my-ai-usage-daemon";
      # `always`, not `on-failure`: a publisher that exits 0 and stays dead
      # leaves the status line frozen on stale numbers with no error anywhere
      # — which is exactly what the old GUI-preferring wrapper did. `always`
      # means a clean exit still gets relaunched.
      Restart = "always";
      RestartSec = 30;
      # It exists to keep the desktop responsive; it must never be the reason
      # memory gets tight. A scan is small, so a low cap is a real bound, and
      # deprioritising it means it yields under exactly the pressure it prevents.
      MemoryMax = "128M";
      Nice = 19;
      CPUWeight = 20;
    };
    Install.WantedBy = [ "default.target" ];
  };

  # Prefer the tray build, fall back to headless. A shell wrapper rather than
  # two ExecStart= lines because systemd would run BOTH: `-` only ignores the
  # failure, it does not stop the sequence. The tray exiting non-zero (no
  # display, no StatusNotifier host) must hand over to headless, not run
  # alongside it — two publishers would fight over the same snapshot file.
  xdg.desktopEntries = {
    my-ai = {
      name = "My AI";
      comment = "Claude Code CLI via Headroom compression proxy";
      exec = "my-ai --help";
      icon = "utilities-terminal";
      terminal = true;
      categories = [ "Development" "ConsoleOnly" ];
    };
    claude-superset-tray = {
      name = "Claude Superset Tray";
      comment = "System-tray helper — live Headroom savings stats, dashboard & status launcher";
      exec = "claude-superset-tray";
      icon = "utilities-terminal";
      terminal = false;
      categories = [ "System" "Monitor" ];
      settings.NoDisplay = "true";
    };
  };

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
