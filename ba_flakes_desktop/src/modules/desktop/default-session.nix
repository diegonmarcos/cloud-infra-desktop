# default-session.nix — DECLARATIVE default 4-desktop login layout.
#
# Supersedes the Plasma-native session-restore path (./session-restore.nix) with
# an EXPLICIT, data-driven launcher (the approach session-restore.nix's header
# called "abandoned" — now viable because per-desktop pinning + L/R tiling are
# done via a KWin script keyed on PID, and Konsole tab titles are made sticky via
# setTabTitleFormat over DBus).
#
# PIECES (all driven by ./default-session.json — the single source of truth):
#   1. default-session.json          → the layout DATA (edit this to change anything)
#   2. default-session-launcher.sh   → the ENGINE (launch + title + pin + tile)
#   3. autostart/.desktop            → fires the engine ONCE per real login
#
# WHAT GUARDS IT (rewritten 2026-08-21):
#   The launcher used to gate on `noresume` in /proc/cmdline (.fallback.run_on
#   = fresh_only). That tested which rEFInd entry was booted, not what the
#   kernel did: booting "NixOS - Primary" with no hibernation image on disk
#   cold-boots into a genuinely fresh session, and the gate skipped it. Verified
#   on 2026-08-21 — cmdline carried resume=, the kernel loaded 0 hibernation
#   images, and a fresh session got no layout.
#
#   A real hibernate resume restores the session from the RAM image, so
#   ksmserver never restarts and this autostart never fires. "Restore from
#   snapshot" is therefore correct with no code at all, and the boot-type gate
#   could only ever produce false negatives. It is gone.
#
#   The guard is now emptiness: apply the layout only when none of its apps are
#   already running. That is the question every previous proxy was trying to
#   answer, it is idempotent by construction, and it cannot duplicate however
#   many times the autostart fires (28 times in one second, on the last login
#   before this rewrite).
#
# "NEVER HOLDS THE LOGIN" (the user's hard requirement):
#   The launcher runs from a Plasma autostart entry (X-KDE-autostart-condition=
#   ksmserver) — i.e. AFTER the session is up, so it cannot block login. Every app
#   is spawned detached, every wait is `timeout`-bounded, every failure is logged
#   and skipped, and the script always exits 0. Thresholds live in the JSON
#   .fallback block. (See default-session-launcher.sh header.)
#
# It only fires at a genuine login — NOT on `build.sh switch` — because it is a
# Plasma autostart .desktop, not a systemd unit that home-manager would restart.
{ config, lib, pkgs, ... }:
let
  shareDir = ".local/share/default-session";
  launcher = "${config.home.homeDirectory}/${shareDir}/default-session-launcher.sh";
  # home.file deploys launcher + json as SEPARATE /nix/store symlinks, so the
  # launcher's readlink-based SELF_DIR can't find the json beside it. Pass the
  # deployed json path explicitly via the env override the launcher honours.
  jsonPath = "${config.home.homeDirectory}/${shareDir}/default-session.json";
in
{
  # ── Deploy the engine + data (source-of-truth files, read at runtime) ──────
  home.file."${shareDir}/default-session-launcher.sh" = {
    source = ./default-session-launcher.sh;
    executable = true;
  };
  home.file."${shareDir}/default-session.json".source = ./default-session.json;

  # jq is the launcher's only hard dependency that isn't part of KDE/the session.
  home.packages = [ pkgs.jq ];

  # Login behaviour (loginMode) is NOT declared here. ./session-default-config.nix
  # owns it — it is the file that decides whether this launcher's work is wanted,
  # and having the switch live next to the thing it switches is what stopped
  # session-restore.nix and this file setting it from two directions. It is set
  # to emptySession there, so Plasma's restore does not double-launch on top of
  # this layout.

  # ── Fire the engine once per real login ────────────────────────────────────
  xdg.configFile."autostart/default-session.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Default Session Layout
    Comment=Restore Diego's default 4-desktop window arrangement (data: default-session.json)
    Exec=sh -c "DEFAULT_SESSION_JSON=${jsonPath} exec ${launcher}"
    X-KDE-autostart-condition=ksmserver
    X-KDE-autostart-phase=2
    OnlyShowIn=KDE;
    NoDisplay=true
  '';

  # ── Dead-man re-dispatch — 2026-08-22 incident ─────────────────────────────
  # The autostart above is dispatched by Plasma's phase-2 machinery, which died
  # WITH plasmashell when it SEGV'd during the login panel apply: the .desktop
  # never fired and the layout silently never appeared (the launcher log has
  # zero entries for that login). This oneshot is the belt: it fires once per
  # graphical login (graphical-session.target — HM switches don't restart the
  # target, hibernate resumes never re-reach it), waits out the login storm,
  # and invokes the SAME launcher. The launcher's flock + emptiness guard make
  # a double-fire a no-op, so autostart + dead-man can never duplicate the
  # layout — this does not weaken the "fires once per real login" contract.
  systemd.user.services.default-session-deadman = {
    Unit = {
      Description = "Default-session dead-man — fires the layout launcher if phase-2 autostart never did";
      After = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      Type = "oneshot";
      TimeoutStartSec = 600;
      ExecStart = toString (pkgs.writeShellScript "default-session-deadman" ''
        # Give phase-2 autostart every chance to have already done the job —
        # if it did, the launcher's emptiness guard makes this a no-op.
        sleep 75
        DEFAULT_SESSION_JSON=${jsonPath} exec ${launcher}
      '');
    };
  };

  # ── Autostart hygiene — 2026-08-22 ─────────────────────────────────────────
  # HM's timestamped `-b` backups accumulate in ~/.config/autostart and Plasma
  # EXECUTES them: 31 concurrent launcher invocations on one login (the flock
  # + emptiness guard saved the layout, not the machine). Autostart is the one
  # directory where a stale backup is live ammunition — purge them after every
  # switch. (No `exit`, activation-snippet rule; `rm -f` is glob-miss-safe.)
  home.activation.purgeAutostartBackups = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run rm -f "$HOME/.config/autostart/"*.hm-bak* "$HOME/.config/autostart/"*.hm-backup* || true
  '';
}
