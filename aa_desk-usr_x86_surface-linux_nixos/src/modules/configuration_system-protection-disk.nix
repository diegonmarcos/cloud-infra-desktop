# System Protection — Disk defense (data-driven)
#
# Reads from cloud-data-disk-protection.json (expected to be copied into
# this module dir by build.sh before `nix build`). Produces:
#   1. systemd-tmpfiles rules for /tmp worktree cleanup
#   2. services.journald limits
#   3. disk-watchdog.service + .timer with thresholds from JSON
#   4. Weekly housekeeping (docker prune, cargo-sweep, nix-gc)
#
# To activate: add to imports of configuration_system-protection.nix
#   AFTER adding this line to build.sh (next to other cloud-data copies):
#     cp ../../cloud-data/cloud-data-disk-protection.json src/modules/
#
{ config, pkgs, lib, ... }:

let
  jsonPath = ./cloud-data-disk-protection.json;
  cfg =
    if builtins.pathExists jsonPath
    then builtins.fromJSON (builtins.readFile jsonPath)
    else {
      _fallback = true;
      tmpfiles_rules.rules = [
        "d /tmp/*-work-*    - - - 4h   -"
        "d /tmp/.tmp*       - - - 1h   -"
      ];
      journald_limits = {
        SystemMaxUse = "500M";
        SystemKeepFree = "200M";
        MaxRetentionSec = "14d";
      };
      watches.mounts = [];
      docker_retention.enabled = false;
      cargo_sweep.enabled = false;
      nix_gc.enabled = false;
    };

  # Journal-flood guard (the invisible-failure-mode voter) config.
  jflood        = cfg.journal_flood_guard or {};
  jfloodEnabled = jflood.enabled or false;
  # OnUnitActiveSec needs the timer interval at BUILD time (systemd unit
  # config), so jfloodInt stays Nix-side. Every other jflood value is read
  # at RUNTIME by journal-flood-guard.sh via jq — see that file.
  jfloodInt     = jflood.interval_sec or 60;

  # Disk watchdog — script lives in disk-watchdog.sh (kept out of the Nix
  # module; inline scripts inside flake/nix modules are forbidden here).
  # It is fully DATA-DRIVEN: reads ALL thresholds, mounts, slice names and
  # actions at RUNTIME from /etc/cloud-data/disk-protection.json via jq —
  # nothing is baked in by Nix interpolation. See environment.etc below for
  # how that JSON gets deployed, and disk-watchdog.sh for the escalation
  # logic (RECLAIM-FIRST -> recheck_gate self-heal -> freeze -> kill, the
  # no-mercy cooldown-void floor, and the mountpoint-guard warning log).
  diskWatchdogPkg = pkgs.writeShellApplication {
    name = "disk-watchdog";
    text = builtins.readFile ./disk-watchdog.sh;
    runtimeInputs = with pkgs; [
      coreutils    # df, date, stat, touch, tr, cut
      findutils    # find
      util-linux   # logger, wall, mountpoint
      systemd      # systemctl, systemd-tmpfiles
      curl         # ntfy alerts
      jq           # runtime config parsing
      nix          # nix-collect-garbage, nix store gc
      gawk         # awk-dependent action scripts (if any)
      btrfs-progs  # btrfs-aware mounts
    ];
  };

  # Journal-flood guard — script lives in journal-flood-guard.sh (kept out of
  # the Nix module; inline scripts inside flake/nix modules are forbidden
  # here). It is fully DATA-DRIVEN: reads ALL thresholds, the never-restart
  # denylist, the restart-loudest-unit switch and the ntfy priority/topic at
  # RUNTIME from /etc/cloud-data/disk-protection.json via jq — nothing is
  # baked in by Nix interpolation.
  journalFloodGuardPkg = pkgs.writeShellApplication {
    name = "journal-flood-guard";
    text = builtins.readFile ./journal-flood-guard.sh;
    runtimeInputs = with pkgs; [
      coreutils    # wc, awk-adjacent
      systemd      # journalctl, systemctl
      util-linux   # logger
      curl         # ntfy alerts
      jq           # runtime config parsing
      gawk         # awk
      gnugrep      # grep -qE
      gnused
    ];
  };

  # Weekly housekeeping — script lives in disk-housekeeping-weekly.sh (kept
  # out of the Nix module; inline scripts inside flake/nix modules are
  # forbidden here). It is fully DATA-DRIVEN: whether each section runs
  # (docker prune / cargo-sweep / nix-gc), the disk-pct gate and the
  # keep-days for each are read at RUNTIME from
  # /etc/cloud-data/disk-protection.json via jq — nothing is baked in by
  # Nix interpolation.
  diskHousekeepingWeeklyPkg = pkgs.writeShellApplication {
    name = "disk-housekeeping-weekly";
    text = builtins.readFile ./disk-housekeeping-weekly.sh;
    runtimeInputs = with pkgs; [
      coreutils
      docker
      cargo-sweep
      nix
      jq
      util-linux   # logger
    ];
  };

in
{
  # ═══════════════════════════════════════════════════════════════════════════
  # SYSTEMD-TMPFILES: worktree + scratch cleanup rules (declarative)
  # ═══════════════════════════════════════════════════════════════════════════
  systemd.tmpfiles.rules = cfg.tmpfiles_rules.rules or [];

  # ═══════════════════════════════════════════════════════════════════════════
  # JOURNALD LIMITS (from JSON)
  # ═══════════════════════════════════════════════════════════════════════════
  # Map JSON journald_limits → journald.conf, skipping `_`-prefixed doc keys
  # (_comment etc.) so they never leak in as bogus `_comment=` config lines.
  services.journald.extraConfig = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (k: v: "${k}=${toString v}")
      (lib.filterAttrs (k: _: !(lib.hasPrefix "_" k)) (cfg.journald_limits or {}))
  );

  # ═══════════════════════════════════════════════════════════════════════════
  # DISK-WATCHDOG — data-driven thresholds
  # ═══════════════════════════════════════════════════════════════════════════
  # disk-watchdog.sh reads its config at RUNTIME from this path via jq — it is
  # not currently deployed anywhere else, and the JSON's own self-tests
  # (`testers.checks`) already assume it exists at /etc/cloud-data/disk-protection.json.
  # A missing/unreadable/unparseable file makes the script exit non-zero
  # rather than silently running with empty thresholds.
  environment.etc."cloud-data/disk-protection.json".source = ./cloud-data-disk-protection.json;

  systemd.timers."disk-watchdog-v2" = lib.mkIf ((cfg.watches.mounts or []) != []) {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
    };
  };

  systemd.services."disk-watchdog-v2" = lib.mkIf ((cfg.watches.mounts or []) != []) {
    serviceConfig = {
      Type = "oneshot";
      Slice = "os-essentials.slice";
      OOMScoreAdjust = -900;
    };
    script = "${diskWatchdogPkg}/bin/disk-watchdog";
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # JOURNAL-FLOOD GUARD — the invisible-failure-mode voter (PSI-blind storms)
  # Isolated unit (NOT in freeze-guard's loop). Watches aggregate journal
  # line-rate; on flood, restarts the single loudest unit + urgent ntfy.
  # ═══════════════════════════════════════════════════════════════════════════
  systemd.timers."journal-flood-guard" = lib.mkIf jfloodEnabled {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "${toString jfloodInt}s";
    };
  };

  systemd.services."journal-flood-guard" = lib.mkIf jfloodEnabled {
    serviceConfig = {
      Type = "oneshot";
      Slice = "os-essentials.slice";
      OOMScoreAdjust = -900;
      IOSchedulingClass = "idle";
    };
    script = "${journalFloodGuardPkg}/bin/journal-flood-guard";
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # WEEKLY HOUSEKEEPING (docker prune / cargo-sweep / nix-gc)
  # ═══════════════════════════════════════════════════════════════════════════
  systemd.timers."disk-housekeeping-weekly" = lib.mkIf
    ((cfg.docker_retention.enabled or false) ||
     (cfg.cargo_sweep.enabled or false) ||
     (cfg.nix_gc.enabled or false))
    {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
      };
    };

  systemd.services."disk-housekeeping-weekly" = lib.mkIf
    ((cfg.docker_retention.enabled or false) ||
     (cfg.cargo_sweep.enabled or false) ||
     (cfg.nix_gc.enabled or false))
    {
      serviceConfig = {
        Type = "oneshot";
        Slice = "workload.slice";
        OOMScoreAdjust = 200;
      };
      script = "${diskHousekeepingWeeklyPkg}/bin/disk-housekeeping-weekly";
    };
}
