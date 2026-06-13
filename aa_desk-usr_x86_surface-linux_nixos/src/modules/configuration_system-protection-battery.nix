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
      # Reset the "minutes off AC" counter whenever the AC adapter is
      # PHYSICALLY present (ADP1/online=1), independent of the battery's
      # charging status. ADP1 is a SEPARATE sysfs node from the BAT1 SAM
      # state, so it stays honest even when the battery gauge freezes.
      #
      # 2026-06-13 INCIDENT: the old condition (status=Charging OR
      # status=Full+online) NEVER matched a fully-charged plugged-in
      # Surface — at 100% on AC the status reads "Not charging", not "Full".
      # So the anchor went stale for the whole time the machine sat plugged
      # in, and the instant AC was unplugged `elapsed = now - stale_anchor`
      # blew past max_minutes_off_ac → adp_offline_time hibernated at 100%.
      # Resetting on online_n=1 makes "unplug now" start a fresh clock.
      if [ "$online_n" = "1" ] || [ "$stat" = "Charging" ]; then
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
      # CAPACITY-GATED (2026-06-13): only acts as a fail-safe when the battery
      # ALSO reads at/below require_capacity_below. A pure wall-clock timer
      # is capacity-blind and hibernated at 100% the instant AC dropped; the
      # gate guarantees this can never fire on a healthy charge. (Residual
      # gap: a SAM frozen HIGH while truly draining is no longer caught here —
      # an accepted trade per the owner's "hibernate at low battery ONLY".)
      ${lib.optionalString (vAdpTime.enabled or false) ''
        capfloor=${toString (vAdpTime.require_capacity_below or 100)}
        if [ "$online_n" = "0" ] && [ "$cap_n" -ge 0 ] && [ "$cap_n" -le "$capfloor" ]; then
          last=$(cat "$lastChg" 2>/dev/null || echo "$ts")
          elapsed=$(( ts - last ))
          maxsec=$(( ${toString (vAdpTime.max_minutes_off_ac or 240)} * 60 ))
          if [ "$elapsed" -ge "$maxsec" ]; then
            _crit adp_offline_time
          fi
        fi
      ''}

      # voter: stuck_sam
      # CAPACITY-GATED (2026-06-13): a frozen gauge at 100% on battery used to
      # satisfy "values static + on-battery" and hibernate at full charge.
      # Now it only fires when capacity ALSO reads at/below require_capacity_below,
      # so a healthy static charge can never trip it.
      ${lib.optionalString (vStuck.enabled or false) ''
        minN=${toString (vStuck.min_static_polls or 5)}
        capfloor=${toString (vStuck.require_capacity_below or 100)}
        n=$(wc -l < "$hist")
        if [ "$n" -ge "$minN" ] && [ "$cap_n" -ge 0 ] && [ "$cap_n" -le "$capfloor" ]; then
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
      # Escalation (2026-06-12 incident): if the critical action itself
      # FAILS — e.g. `systemctl hibernate` → "Not enough suitable swap
      # space" because the swapfile's filesystem was destroyed — retrying
      # every poll just rides the battery down to a firmware power-cut.
      # Count consecutive failed critical actions; after max_action_failures
      # escalate to the fallback verb (clean shutdown beats power-cut).
      # Counter resets on any non-critical poll and on any successful action.
      failsFile="$state/action_failures"
      if [ -n "$voters_critical" ]; then
        fails=$(cat "$failsFile" 2>/dev/null || echo 0)
        case "$fails" in (*[!0-9]*|"") fails=0 ;; esac

        if [ "$fails" -ge ${toString maxFails} ]; then
          ${pkgs.util-linux}/bin/logger -t battery-watchdog -p user.crit \
            "CRITICAL voters=[''${voters_critical# }] — ${action} FAILED $fails consecutive times → ESCALATING to ${fallback}"
          echo "[battery-watchdog] ${action} failed $fails times → ESCALATING to ${fallback}"
          exec ${pkgs.systemd}/bin/systemctl ${fallback}
        fi

        ${pkgs.util-linux}/bin/logger -t battery-watchdog \
          "CRITICAL voters=[''${voters_critical# }] cap=$cap stat=$stat enow=$enow vnow=$vnow alarm=$alarm ${acDev}=$online → ${action} (attempt $((fails + 1))/${toString maxFails})"
        echo "[battery-watchdog] CRITICAL voters=[''${voters_critical# }] → ${action}"

        if ${pkgs.systemd}/bin/systemctl ${action}; then
          # Action succeeded (we are back from hibernate/resume) — reset.
          rm -f "$failsFile"
          exit 0
        else
          echo $((fails + 1)) > "$failsFile"
          ${pkgs.util-linux}/bin/logger -t battery-watchdog -p user.crit \
            "${action} FAILED (attempt $((fails + 1))/${toString maxFails}) — will escalate to ${fallback} once the limit is reached"
          exit 1
        fi
      fi

      # Not critical → clear the failure streak.
      rm -f "$failsFile" 2>/dev/null || true

      if [ -n "$voters_low" ]; then
        ${pkgs.util-linux}/bin/logger -t battery-watchdog \
          "LOW voters=[''${voters_low# }] cap=$cap stat=$stat ${acDev}=$online"
        echo "[battery-watchdog] LOW voters=[''${voters_low# }]"
      fi
    '';
  };
}
