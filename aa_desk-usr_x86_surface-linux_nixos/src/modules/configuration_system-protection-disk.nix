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
  jfloodMax     = jflood.lines_per_min_max or 40000;
  jfloodInt     = jflood.interval_sec or 60;
  jfloodRestart = jflood.restart_loudest_unit or false;
  jfloodNtfy    = jflood.ntfy_priority or "urgent";
  jfloodNever   = jflood.never_restart or [];

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
    path = with pkgs; [ coreutils systemd util-linux curl jq gawk ];
    script = ''
      set -u
      WINDOW=60
      MAX=${toString jfloodMax}
      NEVER="${lib.concatStringsSep "|" jfloodNever}"
      # Count lines emitted in the last WINDOW seconds; scale to per-minute.
      n=$(journalctl --since "''${WINDOW}s ago" -q --no-pager 2>/dev/null | wc -l)
      rate=$(( n * 60 / WINDOW ))
      [ "$rate" -lt "$MAX" ] && exit 0

      # Over threshold — find the single loudest unit in the window.
      unit=$(journalctl --since "''${WINDOW}s ago" -o json --output-fields=_SYSTEMD_UNIT --no-pager 2>/dev/null \
        | jq -r '._SYSTEMD_UNIT // empty' \
        | sort | uniq -c | sort -rn | head -n1 | awk '{print $2}')
      msg="JOURNAL FLOOD: ''${rate} lines/min (>= ''${MAX}). Loudest unit: ''${unit:-unknown}."
      logger -t journal-flood-guard -p user.alert "$msg"
      echo "[journal-flood-guard] $msg"

      # Restart the offender unless it is on the never_restart denylist or empty.
      base=''${unit%.service}; base=''${base%.scope}; base=''${base%.slice}
      if ${lib.boolToString jfloodRestart} && [ -n "''${unit:-}" ] \
         && ! printf '%s' "$base" | grep -qE "^(''${NEVER})$"; then
        systemctl restart "$unit" 2>/dev/null \
          && logger -t journal-flood-guard -p user.warning "restarted flooding unit $unit" \
          && msg="$msg Restarted $unit."
      fi
      curl -sS -H "Title: journal flood ''${rate}/min" -H "Priority: ${jfloodNtfy}" -H "Tags: loudspeaker" \
        -d "$msg" https://ntfy.sh/${cfg.actions.alert_ntfy.topic or "diegonmarcos-infra"} 2>/dev/null || true
    '';
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
      path = with pkgs; [ coreutils docker nix ];
      script = ''
        ${lib.optionalString (cfg.docker_retention.enabled or false) ''
          USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
          if [ "$USAGE" -ge "${toString (cfg.docker_retention.only_if_disk_pct_above or 75)}" ]; then
            command -v docker >/dev/null && docker system prune -f 2>/dev/null || true
          fi
        ''}
        ${lib.optionalString (cfg.cargo_sweep.enabled or false) ''
          command -v cargo-sweep >/dev/null && \
            cargo-sweep --time ${toString (cfg.cargo_sweep.keep_days or 30)} \
              /home/diego/.cargo/target 2>/dev/null || true
        ''}
        ${lib.optionalString (cfg.nix_gc.enabled or false) ''
          ${pkgs.nix}/bin/nix-collect-garbage \
            --delete-older-than ${toString (cfg.nix_gc.keep_days or 14)}d 2>/dev/null || true
        ''}
      '';
    };
}
