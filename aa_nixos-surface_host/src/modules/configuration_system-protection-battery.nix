# System Protection — Battery defense (data-driven sysfs watchdog)
#
# WHY THIS EXISTS
# ───────────────
# Hibernate-on-critical-battery is normally driven by:
#     SAM ─→ /sys/class/power_supply/BAT1 (voltage/energy fields)
#     ─→ upowerd ─→ PowerDevil ─→ logind ─→ kernel
#
# On Surface Pro 8 the SAM controller intermittently reports
# `voltage_now=0`, which makes upowerd's percentage math go NaN. PowerDevil
# only acts on numeric threshold crossings so a NaN means: no critical-battery
# action ever fires, the battery drains to physical 0%, the firmware power-cuts
# and your work is lost.
#
# This module bypasses the broken layers. It reads the kernel's `capacity`
# integer (0..100) and `status` string directly from sysfs. `capacity` comes
# from a different code path than the energy/voltage fields and has been
# reliable across all journal logs even when upowerd reported NaN.
#
# Reads thresholds + poll interval + action from
#   cloud-data-battery-protection.json
# (must live in this same modules/ dir so `builtins.readFile` finds it).
#
# Add to imports of configuration.nix to activate.
#
{ config, pkgs, lib, ... }:

let
  jsonPath = ./cloud-data-battery-protection.json;
  cfg =
    if builtins.pathExists jsonPath
    then builtins.fromJSON (builtins.readFile jsonPath)
    else {
      enabled = false;
      watch = { device = "BAT1"; poll_seconds = 60; };
      thresholds = { critical_capacity_pct = 5; low_capacity_pct = 15; require_status = "Discharging"; };
      action_at_critical = { command = "hibernate"; };
    };

  enabled = cfg.enabled or false;
  device  = cfg.watch.device or "BAT1";
  pollSec = cfg.watch.poll_seconds or 60;
  critPct = cfg.thresholds.critical_capacity_pct or 5;
  lowPct  = cfg.thresholds.low_capacity_pct or 15;
  needStatus = cfg.thresholds.require_status or "Discharging";
  action  = cfg.action_at_critical.command or "hibernate";
in
{
  systemd.timers."battery-watchdog" = lib.mkIf enabled {
    description = "Battery sysfs watchdog — poll every ${toString pollSec}s";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec       = "1min";
      OnUnitActiveSec = "${toString pollSec}s";
      AccuracySec     = "10s";
    };
  };

  systemd.services."battery-watchdog" = lib.mkIf enabled {
    description = "Battery sysfs watchdog — hibernate at critical capacity (bypasses upowerd NaN bug on Surface Pro 8 SAM)";
    serviceConfig = {
      Type = "oneshot";
      Slice = "os-essentials.slice";
      OOMScoreAdjust = -900;
    };
    path = with pkgs; [ coreutils util-linux systemd ];
    script = ''
      set -u
      bat="/sys/class/power_supply/${device}"

      if [ ! -r "$bat/capacity" ] || [ ! -r "$bat/status" ]; then
        echo "[battery-watchdog] $bat not present or unreadable — exit 0"
        exit 0
      fi

      cap=$(cat "$bat/capacity")
      stat=$(cat "$bat/status")
      echo "[battery-watchdog] ${device}: ''${cap}% (''${stat})"

      # Sanity: capacity must be 0..100 integer. If not, log and bail —
      # never trigger destructive actions on garbage input.
      if ! printf '%s' "$cap" | grep -qE '^[0-9]+$'; then
        echo "[battery-watchdog] capacity=''${cap} is not a number — exit 0"
        exit 0
      fi
      if [ "$cap" -gt 100 ]; then
        echo "[battery-watchdog] capacity=''${cap} out of range — exit 0"
        exit 0
      fi

      if [ "$stat" != "${needStatus}" ]; then
        # Not in the state we care about (e.g. Charging) — no action.
        exit 0
      fi

      if [ "$cap" -le ${toString critPct} ]; then
        ${pkgs.util-linux}/bin/logger -t battery-watchdog \
          "CRITICAL ''${cap}% ''${stat} — triggering ${action}"
        echo "[battery-watchdog] CRITICAL ''${cap}% ''${stat} — triggering ${action}"
        ${pkgs.systemd}/bin/systemctl ${action}
      elif [ "$cap" -le ${toString lowPct} ]; then
        ${pkgs.util-linux}/bin/logger -t battery-watchdog \
          "LOW ''${cap}% ''${stat}"
        echo "[battery-watchdog] LOW ''${cap}% ''${stat}"
      fi
    '';
  };
}
