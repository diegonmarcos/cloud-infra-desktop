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
    mountChecks = lib.concatMapStringsSep "\n" (m: ''
      # Watch ${m.mount}
      USAGE=$(df "${m.mount}" --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo 0)
      echo "[disk-watchdog] ${m.mount}: ''${USAGE}%"
      if [ "$USAGE" -ge "${toString m.critical_pct}" ]; then
        echo "[disk-watchdog] CRITICAL ${m.mount} ''${USAGE}% >= ${toString m.critical_pct}%"
        # critical actions
        ${lib.concatMapStringsSep "\n        " (a: "run_action ${a}") m.actions_on_critical}
      elif [ "$USAGE" -ge "${toString m.warn_pct}" ]; then
        echo "[disk-watchdog] WARN ${m.mount} ''${USAGE}% >= ${toString m.warn_pct}%"
        ${lib.concatMapStringsSep "\n        " (a: "run_action ${a}") m.actions_on_warn}
      fi
    '') (cfg.watches.mounts or []);
  in ''
    set -u
    run_action() {
      case "$1" in
        alert_ntfy)
          ${pkgs.curl}/bin/curl -sS -H "Title: disk-watchdog" \
            -d "disk pressure detected" \
            https://ntfy.sh/diegonmarcos-infra 2>/dev/null || true ;;
        purge_tmp_worktrees)
          ${pkgs.systemd}/bin/systemd-tmpfiles --clean --prefix=/tmp 2>/dev/null || true ;;
        purge_tmp_dotfiles)
          ${pkgs.findutils}/bin/find /tmp -maxdepth 1 -name '.tmp*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true ;;
        cargo_sweep)
          command -v cargo-sweep >/dev/null 2>&1 && cargo-sweep --time 30 /home/diego/.cargo/target 2>/dev/null || true ;;
        docker_prune_images)
          command -v docker >/dev/null 2>&1 && docker image prune -f 2>/dev/null || true ;;
        docker_prune_volumes_dangling)
          command -v docker >/dev/null 2>&1 && docker volume prune -f 2>/dev/null || true ;;
        nix_gc_14d)
          ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 14d 2>/dev/null || true ;;
        *) echo "[disk-watchdog] unknown action: $1" ;;
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
