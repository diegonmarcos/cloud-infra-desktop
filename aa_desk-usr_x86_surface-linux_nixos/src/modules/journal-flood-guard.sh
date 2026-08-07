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

# Count lines emitted in the last WINDOW seconds; scale to per-minute.
n=$(journalctl --since "${WINDOW}s ago" -q --no-pager 2>/dev/null | wc -l)
rate=$(( n * 60 / WINDOW ))
[ "$rate" -lt "$MAX" ] && exit 0

# Over threshold — find the single loudest unit in the window.
unit=$(journalctl --since "${WINDOW}s ago" -o json --output-fields=_SYSTEMD_UNIT --no-pager 2>/dev/null \
  | jq -r '._SYSTEMD_UNIT // empty' \
  | sort | uniq -c | sort -rn | head -n1 | awk '{print $2}')
msg="JOURNAL FLOOD: ${rate} lines/min (>= ${MAX}). Loudest unit: ${unit:-unknown}."
logger -t journal-flood-guard -p user.alert "$msg"
echo "[journal-flood-guard] $msg"

# Restart the offender unless it is on the never_restart denylist or empty.
base=${unit%.service}; base=${base%.scope}; base=${base%.slice}
if [ "$RESTART" = "true" ] && [ -n "${unit:-}" ] \
   && ! printf '%s' "$base" | grep -qE "^(${NEVER})$"; then
  if systemctl restart "$unit" 2>/dev/null; then
    logger -t journal-flood-guard -p user.warning "restarted flooding unit $unit"
    msg="$msg Restarted $unit."
  fi
fi
curl -sS -H "Title: journal flood ${rate}/min" -H "Priority: ${NTFY_PRIORITY}" -H "Tags: loudspeaker" \
  -d "$msg" "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
