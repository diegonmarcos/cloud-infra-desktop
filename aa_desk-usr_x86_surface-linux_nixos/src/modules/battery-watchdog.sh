#!/usr/bin/env bash
# battery-watchdog.sh — multi-voter hibernate-at-critical battery defense.
#
# Bypasses upowerd NaN + SAM-freeze on Surface Pro 8. Cross-checks BAT1 +
# ADP1 + sample-history + wall-clock so a SAM data-path freeze cannot
# prevent hibernation. ANY enabled voter with critical verdict triggers
# `systemctl <action_at_critical>` (OR-vote). v1 (single capacity check)
# failed on 2026-04-30: BAT1 sysfs was wedged at capacity=100 for 3.5h
# while the laptop drained to firmware power-off — no userspace work was
# saved.
#
# Fully runtime-data-driven: the battery/AC device names, poll interval,
# state dir, history depth, ALL voter thresholds/enables and the
# critical/fallback actions are read from CONFIG_JSON
# (/etc/cloud-data/battery-protection.json) via jq. Nothing is baked in by
# Nix interpolation. See configuration_system-protection-battery.nix for
# how this script is wired (writeShellApplication) and for the
# banned-verb build-time guard against cloud-data-power.json actions.never
# (Surface S3 suspend is broken; hibernate/poweroff only).
set -u

CONFIG_JSON="${BATTERY_PROTECTION_JSON:-/etc/cloud-data/battery-protection.json}"

# Fail LOUDLY and safely if config is missing/unreadable/unparseable — a
# battery watchdog that reads no config must never conclude "everything is
# fine" and silently skip hibernation.
if [ ! -r "$CONFIG_JSON" ]; then
  logger -t battery-watchdog -p user.err "battery-watchdog: CONFIG MISSING/UNREADABLE at $CONFIG_JSON — refusing to run with no thresholds"
  echo "[battery-watchdog] FATAL: config missing/unreadable at $CONFIG_JSON" >&2
  exit 1
fi
if ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t battery-watchdog -p user.err "battery-watchdog: CONFIG UNPARSEABLE at $CONFIG_JSON — refusing to run with no thresholds"
  echo "[battery-watchdog] FATAL: config unparseable at $CONFIG_JSON" >&2
  exit 1
fi

# ───── watch config ─────
batDev=$(jq -r '.watch.battery_device // "BAT1"' "$CONFIG_JSON")
acDev=$(jq -r '.watch.ac_device // "ADP1"' "$CONFIG_JSON")
stateDir=$(jq -r '.watch.state_dir // "/var/lib/battery-watchdog"' "$CONFIG_JSON")
histN=$(jq -r '.watch.history_polls // 10' "$CONFIG_JSON")

# ───── policy config ─────
action=$(jq -r '.policy.action_at_critical // "hibernate"' "$CONFIG_JSON")
fallback=$(jq -r '.policy.action_at_critical_fallback // "poweroff"' "$CONFIG_JSON")
maxFails=$(jq -r '.policy.max_action_failures // 2' "$CONFIG_JSON")

# ───── voter config ─────
vCapEnabled=$(jq -r '.voters.bat_capacity.enabled // false' "$CONFIG_JSON")
vCapCritPct=$(jq -r '.voters.bat_capacity.critical_pct // 5' "$CONFIG_JSON")
vCapLowPct=$(jq -r '.voters.bat_capacity.low_pct // 15' "$CONFIG_JSON")
vCapReqStatus=$(jq -r '.voters.bat_capacity.require_status // "Discharging"' "$CONFIG_JSON")

vEnergyEnabled=$(jq -r '.voters.bat_energy_ratio.enabled // false' "$CONFIG_JSON")
vEnergyCritPct=$(jq -r '.voters.bat_energy_ratio.critical_pct // 5' "$CONFIG_JSON")
vEnergyReqStatus=$(jq -r '.voters.bat_energy_ratio.require_status // "Discharging"' "$CONFIG_JSON")

vVoltEnabled=$(jq -r '.voters.voltage_under_min.enabled // false' "$CONFIG_JSON")
vVoltMarginUv=$(jq -r '.voters.voltage_under_min.margin_uV // 0' "$CONFIG_JSON")
vVoltReqStatus=$(jq -r '.voters.voltage_under_min.require_status // "Discharging"' "$CONFIG_JSON")

vAlarmEnabled=$(jq -r '.voters.firmware_alarm.enabled // false' "$CONFIG_JSON")

vAdpTimeEnabled=$(jq -r '.voters.adp_offline_time.enabled // false' "$CONFIG_JSON")
vAdpTimeMaxMinutesOffAc=$(jq -r '.voters.adp_offline_time.max_minutes_off_ac // 240' "$CONFIG_JSON")
vAdpTimeReqCapBelow=$(jq -r '.voters.adp_offline_time.require_capacity_below // 100' "$CONFIG_JSON")

vStuckEnabled=$(jq -r '.voters.stuck_sam.enabled // false' "$CONFIG_JSON")
vStuckMinStaticPolls=$(jq -r '.voters.stuck_sam.min_static_polls // 5' "$CONFIG_JSON")
vStuckReqCapBelow=$(jq -r '.voters.stuck_sam.require_capacity_below // 100' "$CONFIG_JSON")

bat_path="/sys/class/power_supply/$batDev"
ac_path="/sys/class/power_supply/$acDev"
state="$stateDir"
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
tail -n "$histN" "$hist" > "$hist.tmp" && mv "$hist.tmp" "$hist"

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
if [ ! -r "$lastChg" ]; then
  echo "$ts" > "$lastChg"
fi

# ───── voter results ─────
voters_critical=""
voters_low=""
_crit() { voters_critical="$voters_critical $1"; }
_low()  { voters_low="$voters_low $1"; }

# voter: bat_capacity
if [ "$vCapEnabled" = "true" ]; then
  if [ "$cap_n" -ge 0 ] && [ "$stat" = "$vCapReqStatus" ]; then
    if [ "$cap_n" -le "$vCapCritPct" ]; then
      _crit bat_capacity
    elif [ "$cap_n" -le "$vCapLowPct" ]; then
      _low bat_capacity
    fi
  fi
fi

# voter: bat_energy_ratio
if [ "$vEnergyEnabled" = "true" ]; then
  if [ "$enow_n" -ge 0 ] && [ "$efull_n" -gt 0 ] && [ "$stat" = "$vEnergyReqStatus" ]; then
    ratio=$(( 100 * enow_n / efull_n ))
    if [ "$ratio" -le "$vEnergyCritPct" ]; then
      _crit bat_energy_ratio
    fi
  fi
fi

# voter: voltage_under_min
if [ "$vVoltEnabled" = "true" ]; then
  if [ "$vnow_n" -gt 0 ] && [ "$vmin_n" -gt 0 ] && [ "$stat" = "$vVoltReqStatus" ]; then
    if [ "$vnow_n" -lt $(( vmin_n - vVoltMarginUv )) ]; then
      _crit voltage_under_min
    fi
  fi
fi

# voter: firmware_alarm
if [ "$vAlarmEnabled" = "true" ]; then
  if [ "$alarm_n" -gt 0 ]; then
    _crit firmware_alarm
  fi
fi

# voter: adp_offline_time
# CAPACITY-GATED (2026-06-13): only acts as a fail-safe when the battery
# ALSO reads at/below require_capacity_below. A pure wall-clock timer
# is capacity-blind and hibernated at 100% the instant AC dropped; the
# gate guarantees this can never fire on a healthy charge. (Residual
# gap: a SAM frozen HIGH while truly draining is no longer caught here —
# an accepted trade per the owner's "hibernate at low battery ONLY".)
if [ "$vAdpTimeEnabled" = "true" ]; then
  if [ "$online_n" = "0" ] && [ "$cap_n" -ge 0 ] && [ "$cap_n" -le "$vAdpTimeReqCapBelow" ]; then
    last=$(cat "$lastChg" 2>/dev/null || echo "$ts")
    elapsed=$(( ts - last ))
    maxsec=$(( vAdpTimeMaxMinutesOffAc * 60 ))
    if [ "$elapsed" -ge "$maxsec" ]; then
      _crit adp_offline_time
    fi
  fi
fi

# voter: stuck_sam
# CAPACITY-GATED (2026-06-13): a frozen gauge at 100% on battery used to
# satisfy "values static + on-battery" and hibernate at full charge.
# Now it only fires when capacity ALSO reads at/below require_capacity_below,
# so a healthy static charge can never trip it.
if [ "$vStuckEnabled" = "true" ]; then
  if [ "$(wc -l < "$hist")" -ge "$vStuckMinStaticPolls" ] && [ "$cap_n" -ge 0 ] && [ "$cap_n" -le "$vStuckReqCapBelow" ]; then
    # static = {cap, enow, vnow} unchanged across last vStuckMinStaticPolls polls
    uniq=$(tail -n "$vStuckMinStaticPolls" "$hist" | awk '{print $2,$4,$5}' | sort -u | wc -l)
    # at least one on-battery indicator in window
    onbat=$(tail -n "$vStuckMinStaticPolls" "$hist" | awk '$3=="Discharging" || $6==0 {c++} END{print c+0}')
    if [ "$uniq" = "1" ] && [ "$onbat" -ge 1 ]; then
      _crit stuck_sam
    fi
  fi
fi

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

  if [ "$fails" -ge "$maxFails" ]; then
    logger -t battery-watchdog -p user.crit \
      "CRITICAL voters=[${voters_critical# }] — $action FAILED $fails consecutive times → ESCALATING to $fallback"
    echo "[battery-watchdog] $action failed $fails times → ESCALATING to $fallback"
    exec systemctl "$fallback"
  fi

  logger -t battery-watchdog \
    "CRITICAL voters=[${voters_critical# }] cap=$cap stat=$stat enow=$enow vnow=$vnow alarm=$alarm ${acDev}=$online → $action (attempt $((fails + 1))/${maxFails})"
  echo "[battery-watchdog] CRITICAL voters=[${voters_critical# }] → $action"

  if systemctl "$action"; then
    # Action succeeded (we are back from hibernate/resume) — reset.
    rm -f "$failsFile"
    exit 0
  else
    echo $((fails + 1)) > "$failsFile"
    logger -t battery-watchdog -p user.crit \
      "$action FAILED (attempt $((fails + 1))/${maxFails}) — will escalate to $fallback once the limit is reached"
    exit 1
  fi
fi

# Not critical → clear the failure streak.
rm -f "$failsFile" 2>/dev/null || true

if [ -n "$voters_low" ]; then
  logger -t battery-watchdog \
    "LOW voters=[${voters_low# }] cap=$cap stat=$stat ${acDev}=$online"
  echo "[battery-watchdog] LOW voters=[${voters_low# }]"
fi
