#!/usr/bin/env bash
# prochot-guard.sh — detect EC BD_PROCHOT hardware CPU clamp (PSI-invisible).
#
# Fully runtime-data-driven: the sustained-strike count and the notify-send
# target uid are read from CONFIG_JSON (/etc/cloud-data/system-protection.json)
# via jq. Nothing is baked in by Nix. See configuration_system-protection.nix
# for how this script is wired (writeShellApplication + environment.etc
# deploy of the JSON) and cloud-data-system-protection.json[.prochot_guard]
# for the config + rationale.
#
# Built via pkgs.writeShellApplication — runtimeInputs supplies msr-tools,
# libnotify, gawk, coreutils, jq, sudo.
set -u

CONFIG_JSON="${SYSTEM_PROTECTION_JSON:-/etc/cloud-data/system-protection.json}"

# Fail LOUDLY and safely if config is missing/unreadable/unparseable — a
# guard that reads no config must never conclude "everything is fine".
if [ ! -r "$CONFIG_JSON" ]; then
  logger -t prochot-guard -p user.err "prochot-guard: CONFIG MISSING/UNREADABLE at $CONFIG_JSON — refusing to run with no thresholds"
  echo "[prochot-guard] FATAL: config missing/unreadable at $CONFIG_JSON" >&2
  exit 1
fi
if ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t prochot-guard -p user.err "prochot-guard: CONFIG UNPARSEABLE at $CONFIG_JSON — refusing to run with no thresholds"
  echo "[prochot-guard] FATAL: config unparseable at $CONFIG_JSON" >&2
  exit 1
fi

SUSTAIN_CHECKS=$(jq -r '.prochot_guard.sustain_checks' "$CONFIG_JSON")
NOTIFY_USER_UID=$(jq -r '.prochot_guard.notify_user_uid' "$CONFIG_JSON")

cur=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
min=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq)
state=/run/prochot-guard.count
if [ "$cur" -lt $(( min * 9 / 10 )) ]; then
  n=$(( $(cat "$state" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$state"
  echo "PROCHOT-GUARD: cpu0 at ${cur}kHz < floor ${min}kHz (strike $n)"
  if [ "$n" -ge "$SUSTAIN_CHECKS" ]; then
    prochot=$(( $(rdmsr -d 0x1FC 2>/dev/null || echo 0) & 1 ))
    echo "PROCHOT-GUARD CRIT: hardware clamp sustained, BD_PROCHOT=$prochot — EC power-drain needed (shutdown, unplug, hold power 30s)"
    wrmsr -a 0x1FC $(( $(rdmsr -d 0x1FC) & ~1 )) 2>/dev/null || true   # best-effort; EC may re-latch
    sudo -u "#${NOTIFY_USER_UID}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${NOTIFY_USER_UID}/bus" \
      notify-send -u critical "CPU HARDWARE-CLAMPED at $(( cur / 1000 ))MHz" \
      "EC asserted BD_PROCHOT ($prochot). PSI cannot see this. Fix: full shutdown, unplug charger, hold power 30s." 2>/dev/null || true
  fi
else
  rm -f "$state"
fi
