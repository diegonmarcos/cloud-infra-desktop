# System Protection — Desktop Session (KDE Plasma 6 memory caps + watchdog)
#
# Why: long-uptime KDE sessions bloat kwin_wayland and plasmashell until they
# crash the Wayland session (live evidence: 2026-04-28 21:15, 2-day session,
# kwin 1.1G+815M swap, plasmashell 692M+983M swap, ksystemstats 42min CPU
# leak). earlyoom won't intervene — it has --avoid for these services and
# rightly so (killing kwin tears the session).
#
# This module declaratively:
#   1. Installs a periodic user-timer watchdog that proactively restarts/notifies
#      a leaky service before it gets bad enough to matter
#
# 2026-08-07: no longer drops per-service MemoryHigh/MemoryMax units. That was
# an independent hard-cap kill path competing with the global PSI watchdog
# (freeze-guard + systemd-oomd) — plasmashell's own cap caused two freeze/crash
# incidents via memory.high throttle-thrash. The global watchdog is now the
# only kill authority; this module is purely proactive (restart before it
# matters), never punitive.
#
# Source of truth: ./system-protection-desktop-session.json
# Engine:          ./system-protection-desktop-session-watchdog.sh
# Tester:          ./test-system-protection-desktop-session.sh
#
# Imported by: system-protection.nix (orchestrator)
#
{ config, pkgs, lib, ... }:

let
  cfg = builtins.fromJSON (builtins.readFile ./system-protection-desktop-session.json);

  watchdogIntervalMin = cfg.watchdog.interval_minutes;
  watchdogBootDelay   = cfg.watchdog.boot_delay_minutes;
in
{
  home.packages = [ pkgs.jq pkgs.libnotify ];

  home.file = {
    # Stable config path — the watchdog reads this
    ".config/system-protection-desktop-session/services.json".source =
      ./system-protection-desktop-session.json;

    # Watchdog engine on $PATH
    ".local/bin/system-protection-desktop-watchdog" = {
      source = ./system-protection-desktop-session-watchdog.sh;
      executable = true;
    };
  };

  systemd.user.services.system-protection-desktop-watchdog = {
    Unit = {
      Description = "Plasma memory watchdog (proactive restart of leaky services)";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/system-protection-desktop-watchdog";
    };
  };

  systemd.user.timers.system-protection-desktop-watchdog = {
    Unit.Description = "Periodic Plasma memory check";
    Timer = {
      OnBootSec = "${toString watchdogBootDelay}min";
      OnUnitActiveSec = "${toString watchdogIntervalMin}min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
