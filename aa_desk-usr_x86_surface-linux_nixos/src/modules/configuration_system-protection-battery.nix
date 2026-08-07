# System Protection — Battery defense (data-driven multi-voter sysfs watchdog)
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
# v1 of this module bypassed upowerd by reading the kernel `capacity` integer
# direct. That assumed `capacity` lives on a different code path than
# voltage/energy. Wrong: on the Surface (drivers/power/supply/surface_battery.c)
# `capacity` is derived from `energy_now / energy_full`; both share the SAM
# state struct. On 2026-04-30 SAM wedged: capacity=100 / status=Full|Discharging
# flapping / present=0 once / for 3.5h while the battery actually drained.
# v1 never reached its `cap ≤ 5` branch and the system died at 22:58:15 with
# zero hibernate attempts.
#
# v2 introduces multiple independent voters (any one trips → hibernate):
#   bat_capacity        — original v1 check (kept for fast path on healthy SAM)
#   bat_energy_ratio    — computed energy_now/energy_full ratio
#   voltage_under_min   — voltage_now < voltage_min_design under load
#   firmware_alarm      — sysfs `alarm` field non-zero (firmware low alarm)
#   adp_offline_time    — wall-clock fail-safe: AC unplugged for too long
#   stuck_sam           — last N samples static + on-battery indicator seen
#
# Voter configuration + thresholds + poll interval + action live in
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
      watch = { battery_device = "BAT1"; ac_device = "ADP1"; poll_seconds = 60; state_dir = "/var/lib/battery-watchdog"; history_polls = 10; };
      voters = {};
      policy = { vote_logic = "any"; action_at_critical = "hibernate"; };
    };

  enabled  = cfg.enabled or false;
  watch    = cfg.watch or {};
  voters   = cfg.voters or {};
  policy   = cfg.policy or {};

  batDev   = watch.battery_device or "BAT1";
  acDev    = watch.ac_device or "ADP1";
  pollSec  = watch.poll_seconds or 60;
  stateDir = watch.state_dir or "/var/lib/battery-watchdog";
  histN    = watch.history_polls or 10;

  # Hard guard (same pattern as configuration_power.nix): refuse any verb
  # banned by cloud-data-power.json actions.never (sleep/suspend — Surface
  # S3 is broken). Applies to the primary action AND the fallback.
  banned = (builtins.fromJSON (builtins.readFile ./cloud-data-power.json)).actions.never or [];
  guard = name: v:
    if builtins.elem v banned
    then throw "configuration_system-protection-battery: ${name}=${v} is in actions.never (Surface S3 is broken)"
    else v;

  action   = guard "policy.action_at_critical" (policy.action_at_critical or "hibernate");
  fallback = guard "policy.action_at_critical_fallback" (policy.action_at_critical_fallback or "poweroff");
  maxFails = policy.max_action_failures or 2;

  # StateDirectory= takes a relative path under /var/lib. Strip prefix.
  stateDirRel =
    let p = "/var/lib/";
    in if lib.hasPrefix p stateDir
       then lib.removePrefix p stateDir
       else "battery-watchdog";

  # Battery watchdog — script lives in battery-watchdog.sh (kept out of the
  # Nix module; inline scripts inside flake/nix modules are forbidden here).
  # It is fully DATA-DRIVEN: the battery/AC device names, poll interval,
  # state dir, history depth, every voter's enabled flag + thresholds and
  # the critical/fallback actions are read at RUNTIME from
  # /etc/cloud-data/battery-protection.json via jq — nothing is baked in by
  # Nix interpolation. `action`/`fallback` above are still computed here
  # too (from the same source JSON) purely so the `guard` throw below can
  # catch a banned verb at BUILD time; the runtime script independently
  # re-reads and validates the same values via jq.
  batteryWatchdogPkg = pkgs.writeShellApplication {
    name = "battery-watchdog";
    text = builtins.readFile ./battery-watchdog.sh;
    runtimeInputs = with pkgs; [
      coreutils    # cat, date, tail, mkdir, cut, wc
      util-linux   # logger
      systemd      # systemctl
      gawk         # history-window parsing
      jq           # runtime config parsing
    ];
  };
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
    description = "Battery sysfs watchdog — multi-voter hibernate at critical (bypasses upowerd NaN + SAM-freeze on Surface Pro 8)";
    serviceConfig = {
      Type = "oneshot";
      Slice = "os-essentials.slice";
      OOMScoreAdjust = -900;
      StateDirectory = stateDirRel;
      StateDirectoryMode = "0750";
    };
    script = "${batteryWatchdogPkg}/bin/battery-watchdog";
  };

  # battery-watchdog.sh reads its config at RUNTIME from this path via jq —
  # this module owns a distinct JSON (not disk-protection.json or
  # system-protection.json, which are already deployed by their own
  # modules), so this is the one place that declares it.
  environment.etc."cloud-data/battery-protection.json".source = ./cloud-data-battery-protection.json;
}
