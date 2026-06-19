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
          msg="DISK EMERGENCY: $mount at $pct% (>= ${toString emergencyPct}%). Stop-the-bleeding: SIGTERM non-system slices [$KILL_SLICES]; FREEZE [$FREEZE_SLICES] so survivor writes HALT during reclaim; os-essentials (ssh/wg/session/watchdog) preserved. Trace: journalctl -t disk-emergency -b"
          ${pkgs.util-linux}/bin/logger -t disk-emergency -p user.alert "$msg"
          echo "$msg"
          ${pkgs.util-linux}/bin/wall "disk-emergency: $mount $pct% full — non-system apps are being stopped to reclaim space. SAVE YOUR WORK." 2>/dev/null || true
          ${pkgs.curl}/bin/curl -sS -H "Title: DISK EMERGENCY $mount $pct%" -H "Priority: ${ntfyPriority}" -H "Tags: rotating_light" \
            -d "$msg" https://ntfy.sh/${ntfyTopic} 2>/dev/null || true ;;
        kill_nonsystem)
          # SIGTERM every process in the non-system background slices — stops the
          # bleeders writing. os-essentials.slice is never in this list.
          for s in $KILL_SLICES; do
            ${pkgs.systemd}/bin/systemctl kill --kill-whom=all -s SIGTERM "$s" 2>/dev/null \
              && ${pkgs.util-linux}/bin/logger -t disk-emergency -p user.warning "SIGTERM -> $s (kill non-system writers)" || true
          done ;;
        freeze_nonsystem)
          # cgroup-v2 freeze — survivor writes halt INSTANTLY (paused, reversible,
          # no data loss) while the reclaim actions run.
          for s in $FREEZE_SLICES; do
            ${pkgs.systemd}/bin/systemctl freeze "$s" 2>/dev/null \
              && ${pkgs.util-linux}/bin/logger -t disk-emergency -p user.warning "FROZE $s -> its writes are halted for cleanup" || true
          done ;;
        thaw_nonsystem)
          # Always the LAST emergency action, so a transient spike never strands a
          # slice frozen.
          for s in $FREEZE_SLICES; do
            ${pkgs.systemd}/bin/systemctl thaw "$s" 2>/dev/null \
              && ${pkgs.util-linux}/bin/logger -t disk-emergency -p user.info "THAWED $s -> reclaim complete, resumed" || true
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
  services.journald.extraConfig = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (k: v: "${k}=${toString v}") (cfg.journald_limits or {})
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
