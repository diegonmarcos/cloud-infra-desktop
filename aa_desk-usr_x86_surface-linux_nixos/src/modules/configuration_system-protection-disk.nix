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

  # Build the watchdog script from declared thresholds + actions.
  mkWatchdogScript = let
    # Emergency (stop-the-bleeding) tier — global, above every per-mount critical.
    emergency        = cfg.emergency or {};
    emergencyActions = emergency.actions or [];
    # Disabled (no actions) → threshold 101 can never fire, so the chain falls
    # straight through to critical/warn. Enabled → fires at emergency.pct (95).
    emergencyPct     = if emergencyActions == [] then 101 else (emergency.pct or 95);
    killSlices       = emergency.kill_slices or [];
    freezeSlices     = emergency.freeze_slices or [];
    protectedSlices  = emergency.protected_slices or [];
    cooldownMin      = emergency.cooldown_minutes or 0;
    ntfyTopic        = cfg.actions.alert_ntfy.topic or "diegonmarcos-infra";
    ntfyPriority     = emergency.ntfy_priority or "urgent";
    mountChecks = lib.concatMapStringsSep "\n" (m: ''
      # Watch ${m.mount}
      if ! ${pkgs.util-linux}/bin/findmnt -n "${m.mount}" >/dev/null 2>&1; then
        echo "[disk-watchdog] ${m.mount}: NOT MOUNTED — skipped"
      else
        USAGE=$(df "${m.mount}" --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
        if ! [[ "$USAGE" =~ ^[0-9]+$ ]]; then
          echo "[disk-watchdog] ${m.mount}: unreadable usage ('$USAGE') — skipped"
        else
          echo "[disk-watchdog] ${m.mount}: ''${USAGE}%"
          if [ "$USAGE" -ge "${toString emergencyPct}" ]; then
            echo "[disk-watchdog] EMERGENCY ${m.mount} ''${USAGE}% >= ${toString emergencyPct}% — stop-the-bleeding"
            ${lib.concatMapStringsSep "\n            " (a: "run_action ${a} ${m.mount} \"$USAGE\"") emergencyActions}
          elif [ "$USAGE" -ge "${toString m.critical_pct}" ]; then
            echo "[disk-watchdog] CRITICAL ${m.mount} ''${USAGE}% >= ${toString m.critical_pct}%"
            ${lib.concatMapStringsSep "\n            " (a: "run_action ${a} ${m.mount} \"$USAGE\"") m.actions_on_critical}
          elif [ "$USAGE" -ge "${toString m.warn_pct}" ]; then
            echo "[disk-watchdog] WARN ${m.mount} ''${USAGE}% >= ${toString m.warn_pct}%"
            ${lib.concatMapStringsSep "\n            " (a: "run_action ${a} ${m.mount} \"$USAGE\"") m.actions_on_warn}
          fi
        fi
      fi
    '') (cfg.watches.mounts or []);
  in ''
    set -u
    KILL_SLICES="${lib.concatStringsSep " " killSlices}"
    FREEZE_SLICES="${lib.concatStringsSep " " freezeSlices}"
    PROTECTED_SLICES="${lib.concatStringsSep " " protectedSlices}"
    COOLDOWN_MIN=${toString cooldownMin}
    # Reclaim-first gate: 1 = still full after reclaim (punish), 0 = self-healed
    # (skip freeze/kill). Defaults to 1 so if recheck_gate is absent from the
    # actions list the old always-punish behavior is preserved.
    EMERG_STILL_FULL=1
    # True iff a slice is in PROTECTED_SLICES — never freeze/kill these.
    is_protected() {
      local q="$1" p
      for p in $PROTECTED_SLICES; do [ "$p" = "$q" ] && return 0; done
      return 1
    }
    run_action() {
      local action="$1" mount="''${2:-?}" pct="''${3:-?}"
      case "$action" in
        alert_ntfy)
          ${pkgs.curl}/bin/curl -sS -H "Title: disk-watchdog $mount $pct%" \
            -d "disk pressure: $mount at $pct%" \
            https://ntfy.sh/diegonmarcos-infra 2>/dev/null || true ;;
        purge_tmp_worktrees)
          ${pkgs.systemd}/bin/systemd-tmpfiles --clean --prefix=/tmp 2>/dev/null || true ;;
        purge_tmp_dotfiles)
          ${pkgs.findutils}/bin/find /tmp -maxdepth 1 -name '.tmp*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true ;;
        purge_audit_old)
          # Bound the audit log dir even when high traffic outpaces tmpfiles cleanup.
          ${pkgs.findutils}/bin/find /mnt/shared/log/audit -type f -mtime +3 -delete 2>/dev/null || true
          ${pkgs.systemd}/bin/systemd-tmpfiles --clean --prefix=/mnt/shared/log/audit 2>/dev/null || true ;;
        cargo_sweep)
          command -v cargo-sweep >/dev/null 2>&1 && cargo-sweep --time 30 /home/diego/.cargo/target 2>/dev/null || true ;;
        docker_prune_images)
          command -v docker >/dev/null 2>&1 && docker image prune -f 2>/dev/null || true ;;
        docker_prune_volumes_dangling)
          command -v docker >/dev/null 2>&1 && docker volume prune -f 2>/dev/null || true ;;
        nix_gc_14d)
          ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 14d 2>/dev/null || true ;;
        dev_store_gc)
          # GC the p5 dev-store chroot store (storeDir=/nix/store, root on p5). The
          # bc_flakes_dev-store profile gcroot pins the current toolchain.
          ${pkgs.nix}/bin/nix store gc --extra-experimental-features nix-command \
            --store 'local?root=/mnt/shared-lib/dev-store&store=/nix/store' 2>/dev/null || true ;;
        emergency_signal)
          # The unmissable "disk is full → stopping writes for cleanup" signal:
          # verbose journal (journalctl -t disk-emergency) + wall to every TTY + urgent ntfy.
          msg="DISK EMERGENCY: $mount at $pct% (>= ${toString emergencyPct}%). RECLAIM-FIRST: pruning docker/nix/tmp now; if that frees enough, NOTHING is frozen or killed. Only if reclaim is insufficient: FREEZE [$FREEZE_SLICES] (pause, reversible) then SIGTERM [$KILL_SLICES] as last resort. Protected [$PROTECTED_SLICES] (ssh/wg/session/watchdog/freeze-guard) always preserved. Trace: journalctl -t disk-emergency -b"
          ${pkgs.util-linux}/bin/logger -t disk-emergency -p user.alert "$msg"
          echo "$msg"
          ${pkgs.util-linux}/bin/wall "disk-emergency: $mount $pct% full — non-system apps are being stopped to reclaim space. SAVE YOUR WORK." 2>/dev/null || true
          ${pkgs.curl}/bin/curl -sS -H "Title: DISK EMERGENCY $mount $pct%" -H "Priority: ${ntfyPriority}" -H "Tags: rotating_light" \
            -d "$msg" https://ntfy.sh/${ntfyTopic} 2>/dev/null || true ;;
        recheck_gate)
          # Re-read usage AFTER reclaim. If reclaim freed enough, self-heal: skip
          # freeze/kill entirely (the box is never disrupted). Else proceed to the
          # last-resort freeze/kill. Sets the global EMERG_STILL_FULL that
          # freeze_nonsystem/kill_nonsystem are gated on.
          local u
          u=$(${pkgs.coreutils}/bin/df "$mount" --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
          if [[ "$u" =~ ^[0-9]+$ ]] && [ "$u" -lt "${toString emergencyPct}" ]; then
            EMERG_STILL_FULL=0
            ${pkgs.util-linux}/bin/logger -t disk-emergency -p user.info "RECLAIM SELF-HEALED $mount -> ''${u}% (< ${toString emergencyPct}%) — SKIPPING freeze/kill, box never disrupted"
            echo "[disk-watchdog] self-healed $mount ''${u}% — no freeze/kill needed"
            ${pkgs.curl}/bin/curl -sS -H "Title: disk self-healed $mount ''${u}%" -H "Priority: default" -H "Tags: white_check_mark" \
              -d "Reclaim freed enough on $mount (now ''${u}%). Freeze/kill skipped — no session disruption." \
              https://ntfy.sh/${ntfyTopic} 2>/dev/null || true
          else
            EMERG_STILL_FULL=1
            ${pkgs.util-linux}/bin/logger -t disk-emergency -p user.warning "RECLAIM INSUFFICIENT $mount -> ''${u}% (still >= ${toString emergencyPct}%) — proceeding to last-resort freeze/kill"
          fi ;;
        freeze_nonsystem)
          # Gated: only if reclaim did NOT self-heal. cgroup-v2 freeze — survivor
          # writes halt INSTANTLY (paused, reversible, no data loss). Never freezes
          # a protected slice.
          [ "''${EMERG_STILL_FULL:-1}" = "1" ] || { echo "[disk-watchdog] freeze skipped (self-healed)"; return 0; }
          for s in $FREEZE_SLICES; do
            is_protected "$s" && { ${pkgs.util-linux}/bin/logger -t disk-emergency -p user.err "REFUSED to freeze protected slice $s"; continue; }
            ${pkgs.systemd}/bin/systemctl freeze "$s" 2>/dev/null \
              && ${pkgs.util-linux}/bin/logger -t disk-emergency -p user.warning "FROZE $s -> its writes are halted for cleanup" || true
          done ;;
        kill_nonsystem)
          # Gated: only if reclaim did NOT self-heal. SIGTERM every process in the
          # non-system background slices. Never targets a protected slice.
          # Cooldown: don't re-SIGTERM the same slices within COOLDOWN_MIN — that
          # repeated kill every 5min was the 2026-07-08 spawn-storm. When on
          # cooldown the freeze + reclaim still ran; we just don't re-kill.
          [ "''${EMERG_STILL_FULL:-1}" = "1" ] || { echo "[disk-watchdog] kill skipped (self-healed)"; return 0; }
          local stamp=/run/disk-emergency-kill.stamp
          if [ "''${COOLDOWN_MIN:-0}" -gt 0 ] && [ -f "$stamp" ]; then
            local age=$(( ( $(${pkgs.coreutils}/bin/date +%s) - $(${pkgs.coreutils}/bin/stat -c %Y "$stamp") ) / 60 ))
            if [ "$age" -lt "''${COOLDOWN_MIN}" ]; then
              ${pkgs.util-linux}/bin/logger -t disk-emergency -p user.warning "SIGTERM SUPPRESSED (cooldown: ''${age}m < ''${COOLDOWN_MIN}m) — froze + reclaimed, not re-killing to avoid spawn-storm"
              return 0
            fi
          fi
          ${pkgs.coreutils}/bin/touch "$stamp" 2>/dev/null || true
          for s in $KILL_SLICES; do
            is_protected "$s" && { ${pkgs.util-linux}/bin/logger -t disk-emergency -p user.err "REFUSED to SIGTERM protected slice $s"; continue; }
            ${pkgs.systemd}/bin/systemctl kill --kill-whom=all -s SIGTERM "$s" 2>/dev/null \
              && ${pkgs.util-linux}/bin/logger -t disk-emergency -p user.warning "SIGTERM -> $s (kill non-system writers)" || true
          done ;;
        thaw_nonsystem)
          # UNGATED and always last, so a transient spike or a run interrupted
          # between freeze and thaw never strands a slice frozen. No-op if already
          # thawed.
          for s in $FREEZE_SLICES; do
            ${pkgs.systemd}/bin/systemctl thaw "$s" 2>/dev/null \
              && ${pkgs.util-linux}/bin/logger -t disk-emergency -p user.info "THAWED $s -> resumed" || true
          done ;;
        *) echo "[disk-watchdog] unknown action: $action" ;;
      esac
    }

    ${mountChecks}
  '';

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
    path = with pkgs; [ coreutils findutils systemd util-linux curl ];
    script = mkWatchdogScript;
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
