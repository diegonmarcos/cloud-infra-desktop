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
  action   = policy.action_at_critical or "hibernate";

  vCap     = voters.bat_capacity     or { enabled = false; };
  vEnergy  = voters.bat_energy_ratio or { enabled = false; };
  vVolt    = voters.voltage_under_min or { enabled = false; };
  vAlarm   = voters.firmware_alarm   or { enabled = false; };
  vAdpTime = voters.adp_offline_time or { enabled = false; };
  vStuck   = voters.stuck_sam        or { enabled = false; };

  # StateDirectory= takes a relative path under /var/lib. Strip prefix.
  stateDirRel =
    let p = "/var/lib/";
    in if lib.hasPrefix p stateDir
       then lib.removePrefix p stateDir
       else "battery-watchdog";
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
    path = with pkgs; [ coreutils util-linux systemd gawk ];
    script = ''
      set -u

      bat_path="/sys/class/power_supply/${batDev}"
      ac_path="/sys/class/power_supply/${acDev}"
      state="${stateDir}"
      hist="$state/history"
      lastChg="$state/last_charging.epoch"

      mkdir -p "$state"

      # ───── read sample ─────
      _read() { if [ -r "$1" ]; then cat "$1"; else echo ""; fi; }
      _num()  { if [ -z "$1" ]; then echo -1; else
                  case "$1" in (*[!0-9]*) echo -1 ;; (*) echo "$1" ;; esac
                fi; }

      ts=$(date +%s)
      cap=$(_read     "$bat_path/capacity")
      stat=$(_read    "$bat_path/status")
      enow=$(_read    "$bat_path/energy_now")
      efull=$(_read   "$bat_path/energy_full")
      vnow=$(_read    "$bat_path/voltage_now")
      vmin=$(_read    "$bat_path/voltage_min_design")
      alarm=$(_read   "$bat_path/alarm")
      present=$(_read "$bat_path/present")
      online=$(_read  "$ac_path/online")

      cap_n=$(_num    "$cap")
      enow_n=$(_num   "$enow")
      efull_n=$(_num  "$efull")
      vnow_n=$(_num   "$vnow")
      vmin_n=$(_num   "$vmin")
      alarm_n=$(_num  "$alarm")
      online_n=$(_num "$online")

      echo "[battery-watchdog] ${batDev}: cap=$cap stat=$stat enow=$enow vnow=$vnow alarm=$alarm ${acDev}=$online"

      # Battery genuinely missing → bail (don't act on garbage).
      if [ "$present" != "1" ]; then
        echo "[battery-watchdog] present=$present — bailing out (no votes)"
        exit 0
      fi

      # ───── update rolling history ─────
      # Format: <ts> <cap_n> <stat> <enow_n> <vnow_n> <online_n> <alarm_n>
      printf '%s %s %s %s %s %s %s\n' \
        "$ts" "$cap_n" "$stat" "$enow_n" "$vnow_n" "$online_n" "$alarm_n" >> "$hist"
      tail -n ${toString histN} "$hist" > "$hist.tmp" && mv "$hist.tmp" "$hist"

      # ───── update last_charging anchor ─────
      # Reset the "minutes off AC" counter only on a positive AC indicator that
      # cannot be faked by stuck SAM data alone:
      #   (status=Charging) OR (status=Full AND ac_online=1)
      if [ "$stat" = "Charging" ] || { [ "$stat" = "Full" ] && [ "$online_n" = "1" ]; }; then
        echo "$ts" > "$lastChg"
      fi
      [ -r "$lastChg" ] || echo "$ts" > "$lastChg"

      # ───── voter results ─────
      voters_critical=""
      voters_low=""
      _crit() { voters_critical="$voters_critical $1"; }
      _low()  { voters_low="$voters_low $1"; }

      # voter: bat_capacity
      ${lib.optionalString (vCap.enabled or false) ''
        if [ "$cap_n" -ge 0 ] && [ "$stat" = "${vCap.require_status or "Discharging"}" ]; then
          if [ "$cap_n" -le ${toString (vCap.critical_pct or 5)} ]; then
            _crit bat_capacity
          elif [ "$cap_n" -le ${toString (vCap.low_pct or 15)} ]; then
            _low bat_capacity
          fi
        fi
      ''}

      # voter: bat_energy_ratio
      ${lib.optionalString (vEnergy.enabled or false) ''
        if [ "$enow_n" -ge 0 ] && [ "$efull_n" -gt 0 ] && [ "$stat" = "${vEnergy.require_status or "Discharging"}" ]; then
          ratio=$(( 100 * enow_n / efull_n ))
          if [ "$ratio" -le ${toString (vEnergy.critical_pct or 5)} ]; then
            _crit bat_energy_ratio
          fi
        fi
      ''}

      # voter: voltage_under_min
      ${lib.optionalString (vVolt.enabled or false) ''
        margin_uV=${toString (vVolt.margin_uV or 0)}
        if [ "$vnow_n" -gt 0 ] && [ "$vmin_n" -gt 0 ] && [ "$stat" = "${vVolt.require_status or "Discharging"}" ]; then
          if [ "$vnow_n" -lt $(( vmin_n - margin_uV )) ]; then
            _crit voltage_under_min
          fi
        fi
      ''}

      # voter: firmware_alarm
      ${lib.optionalString (vAlarm.enabled or false) ''
        if [ "$alarm_n" -gt 0 ]; then
          _crit firmware_alarm
        fi
      ''}

      # voter: adp_offline_time
      ${lib.optionalString (vAdpTime.enabled or false) ''
        if [ "$online_n" = "0" ]; then
          last=$(cat "$lastChg" 2>/dev/null || echo "$ts")
          elapsed=$(( ts - last ))
          maxsec=$(( ${toString (vAdpTime.max_minutes_off_ac or 240)} * 60 ))
          if [ "$elapsed" -ge "$maxsec" ]; then
            _crit adp_offline_time
          fi
        fi
      ''}

      # voter: stuck_sam
      ${lib.optionalString (vStuck.enabled or false) ''
        minN=${toString (vStuck.min_static_polls or 5)}
        n=$(wc -l < "$hist")
        if [ "$n" -ge "$minN" ]; then
          # static = {cap, enow, vnow} unchanged across last minN polls
          uniq=$(tail -n "$minN" "$hist" | awk '{print $2,$4,$5}' | sort -u | wc -l)
          # at least one on-battery indicator in window
          onbat=$(tail -n "$minN" "$hist" | awk '$3=="Discharging" || $6==0 {c++} END{print c+0}')
          if [ "$uniq" = "1" ] && [ "$onbat" -ge 1 ]; then
            _crit stuck_sam
          fi
        fi
      ''}

      # ───── act ─────
      if [ -n "$voters_critical" ]; then
        ${pkgs.util-linux}/bin/logger -t battery-watchdog \
          "CRITICAL voters=[''${voters_critical# }] cap=$cap stat=$stat enow=$enow vnow=$vnow alarm=$alarm ${acDev}=$online → ${action}"
        echo "[battery-watchdog] CRITICAL voters=[''${voters_critical# }] → ${action}"
        exec ${pkgs.systemd}/bin/systemctl ${action}
      fi

      if [ -n "$voters_low" ]; then
        ${pkgs.util-linux}/bin/logger -t battery-watchdog \
          "LOW voters=[''${voters_low# }] cap=$cap stat=$stat ${acDev}=$online"
        echo "[battery-watchdog] LOW voters=[''${voters_low# }]"
      fi
    '';
  };
}
