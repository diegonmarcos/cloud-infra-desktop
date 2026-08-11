#!/usr/bin/env bash
# journal-flood-guard.sh — the invisible-failure-mode voter (PSI-blind storms).
#
# Fully runtime-data-driven: ALL thresholds, the never-restart denylist, the
# restart-loudest-unit switch and the ntfy priority/topic are read from
# CONFIG_JSON (/etc/cloud-data/disk-protection.json) via jq. Nothing is baked
# in by Nix. See configuration_system-protection-disk.nix for how this script
# is wired (writeShellApplication + environment.etc deploy of the JSON).
#
# Built via pkgs.writeShellApplication — runtimeInputs supplies journalctl
# (systemd), jq, curl, logger, systemctl, awk, grep.
set -u

CONFIG_JSON="${DISK_PROTECTION_JSON:-/etc/cloud-data/disk-protection.json}"

# Fail LOUDLY and safely if config is missing/unreadable/unparseable — a
# guard that reads no config must never conclude "everything is fine".
if [ ! -r "$CONFIG_JSON" ]; then
  logger -t journal-flood-guard -p user.err "journal-flood-guard: CONFIG MISSING/UNREADABLE at $CONFIG_JSON — refusing to run with no thresholds"
  echo "[journal-flood-guard] FATAL: config missing/unreadable at $CONFIG_JSON" >&2
  exit 1
fi
if ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t journal-flood-guard -p user.err "journal-flood-guard: CONFIG UNPARSEABLE at $CONFIG_JSON — refusing to run with no thresholds"
  echo "[journal-flood-guard] FATAL: config unparseable at $CONFIG_JSON" >&2
  exit 1
fi

WINDOW=60
MAX=$(jq -r '.journal_flood_guard.lines_per_min_max // 40000' "$CONFIG_JSON")
RESTART=$(jq -r '.journal_flood_guard.restart_loudest_unit // false' "$CONFIG_JSON")
NTFY_PRIORITY=$(jq -r '.journal_flood_guard.ntfy_priority // "urgent"' "$CONFIG_JSON")
NTFY_TOPIC=$(jq -r '.actions.alert_ntfy.topic // "diegonmarcos-infra"' "$CONFIG_JSON")
NEVER=$(jq -r '(.journal_flood_guard.never_restart // []) | join("|")' "$CONFIG_JSON")
# Early-warning ladder: percentages OF MAX at which to alert and do NOTHING else.
# 2026-08-11: this guard had exactly one threshold, and crossing it restarted a
# unit immediately with the notification sent AFTERWARDS — the desktop died with
# no warning of any kind. Three rungs before the terminal action, per project rule.
LADDER=$(jq -r '(.journal_flood_guard.alert_ladder_pct // [60,80,92]) | .[]' "$CONFIG_JSON")

notify() { # notify <title> <priority> <tag> <message>
  logger -t journal-flood-guard -p user.alert "$4"
  echo "[journal-flood-guard] $4"
  curl -sS -H "Title: $1" -H "Priority: $2" -H "Tags: $3" \
    -d "$4" "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
}

# Count lines emitted in the last WINDOW seconds; scale to per-minute.
n=$(journalctl --since "${WINDOW}s ago" -q --no-pager 2>/dev/null | wc -l)
rate=$(( n * 60 / WINDOW ))

# ── Early-warning rungs — alert only, never act. Highest crossed rung wins so a
# single pass emits one message, not three.
if [ "$rate" -lt "$MAX" ]; then
  hit=0
  for pct in $LADDER; do
    thr=$(( MAX * pct / 100 ))
    [ "$rate" -ge "$thr" ] && [ "$thr" -gt "$hit" ] && hit=$thr
  done
  if [ "$hit" -gt 0 ]; then
    loud=$(journalctl --since "${WINDOW}s ago" -o json --output-fields=_SYSTEMD_UNIT --no-pager 2>/dev/null \
      | jq -r '._SYSTEMD_UNIT // empty' | sort | uniq -c | sort -rn | head -n1 | awk '{print $2}')
    notify "journal flood WARNING ${rate}/min" "default" "warning" \
      "JOURNAL FLOOD WARNING: ${rate} lines/min, approaching the ${MAX} action threshold. Loudest: ${loud:-unknown}. Nothing has been restarted — this is a heads-up so the cause can be fixed before the guard acts."
  fi
  exit 0
fi

# ── Terminal tier — over MAX.
# Attribute to the REAL offender. Everything in the desktop session reports
# _SYSTEMD_UNIT=user@<uid>.service (the user MANAGER), so naming that unit and
# "restarting the offender" means restarting the entire session. 2026-08-11:
# plasmashell logged 57k lines in one window, this guard blamed user@1000.service
# and restarted it, and the whole desktop vanished with no warning. The user saw
# a black screen, assumed a crash, and held the power button — a hard power-off
# of a machine whose memory/cpu/io PSI were all 0.00. Drill into
# _SYSTEMD_USER_UNIT so the action lands on plasma-plasmashell.service instead.
unit=$(journalctl --since "${WINDOW}s ago" -o json --output-fields=_SYSTEMD_UNIT --no-pager 2>/dev/null \
  | jq -r '._SYSTEMD_UNIT // empty' \
  | sort | uniq -c | sort -rn | head -n1 | awk '{print $2}')
scope="system"
if printf '%s' "${unit:-}" | grep -qE '^user@[0-9]+\.service$'; then
  uid=$(printf '%s' "$unit" | tr -dc '0-9')
  real=$(journalctl --since "${WINDOW}s ago" -o json --output-fields=_SYSTEMD_USER_UNIT --no-pager 2>/dev/null \
    | jq -r '._SYSTEMD_USER_UNIT // empty' | sort | uniq -c | sort -rn | head -n1 | awk '{print $2}')
  if [ -n "${real:-}" ]; then
    unit="$real"; scope="user:$uid"
  fi
fi

msg="JOURNAL FLOOD: ${rate} lines/min (>= ${MAX}). Loudest unit: ${unit:-unknown} (${scope})."
# Alert BEFORE acting, not after. The old order notified only once the unit was
# already gone, which is useless to anyone watching the screen it just killed.
notify "journal flood ${rate}/min" "$NTFY_PRIORITY" "loudspeaker" "$msg Acting now."
wall "journal-flood-guard: ${unit:-unknown} is flooding the journal (${rate} lines/min) and is being restarted. Your session is NOT being logged out." 2>/dev/null || true

# Restart the offender unless it is on the never_restart denylist or empty.
base=${unit%.service}; base=${base%.scope}; base=${base%.slice}
if [ "$RESTART" = "true" ] && [ -n "${unit:-}" ] \
   && ! printf '%s' "$base" | grep -qE "^(${NEVER})$"; then
  case "$scope" in
    user:*)
      # Restart INSIDE the user manager. `systemctl restart` from root would
      # target a system unit of that name (or nothing); --user --machine reaches
      # the right bus and restarts only the offending app.
      systemctl --user --machine="${scope#user:}@" restart "$unit" 2>/dev/null \
        && logger -t journal-flood-guard -p user.warning "restarted flooding user unit $unit" \
        && msg="$msg Restarted $unit." ;;
    *)
      systemctl restart "$unit" 2>/dev/null \
        && logger -t journal-flood-guard -p user.warning "restarted flooding unit $unit" \
        && msg="$msg Restarted $unit." ;;
  esac
fi
