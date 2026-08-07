#!/usr/bin/env bash
# disk-housekeeping-weekly.sh — docker prune / cargo-sweep / nix-gc.
#
# Fully runtime-data-driven: whether each section runs, the disk-pct gate for
# docker prune, and the keep-days for cargo-sweep/nix-gc are all read from
# CONFIG_JSON (/etc/cloud-data/disk-protection.json) via jq. Nothing is baked
# in by Nix. See configuration_system-protection-disk.nix for how this script
# is wired (writeShellApplication + environment.etc deploy of the JSON).
#
# Built via pkgs.writeShellApplication — runtimeInputs supplies coreutils,
# docker (optional, checked with `command -v`), cargo-sweep (optional), nix,
# jq, logger.
set -u

CONFIG_JSON="${DISK_PROTECTION_JSON:-/etc/cloud-data/disk-protection.json}"

# Fail LOUDLY and safely if config is missing/unreadable/unparseable — weekly
# housekeeping that reads no config must never silently no-op or misfire.
if [ ! -r "$CONFIG_JSON" ]; then
  logger -t disk-housekeeping-weekly -p user.err "disk-housekeeping-weekly: CONFIG MISSING/UNREADABLE at $CONFIG_JSON — refusing to run"
  echo "[disk-housekeeping-weekly] FATAL: config missing/unreadable at $CONFIG_JSON" >&2
  exit 1
fi
if ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t disk-housekeeping-weekly -p user.err "disk-housekeeping-weekly: CONFIG UNPARSEABLE at $CONFIG_JSON — refusing to run"
  echo "[disk-housekeeping-weekly] FATAL: config unparseable at $CONFIG_JSON" >&2
  exit 1
fi

DOCKER_ENABLED=$(jq -r '.docker_retention.enabled // false' "$CONFIG_JSON")
DOCKER_PCT=$(jq -r '.docker_retention.only_if_disk_pct_above // 75' "$CONFIG_JSON")
CARGO_ENABLED=$(jq -r '.cargo_sweep.enabled // false' "$CONFIG_JSON")
CARGO_KEEP_DAYS=$(jq -r '.cargo_sweep.keep_days // 30' "$CONFIG_JSON")
NIXGC_ENABLED=$(jq -r '.nix_gc.enabled // false' "$CONFIG_JSON")
NIXGC_KEEP_DAYS=$(jq -r '.nix_gc.keep_days // 14' "$CONFIG_JSON")

if [ "$DOCKER_ENABLED" = "true" ]; then
  USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
  if [ "$USAGE" -ge "$DOCKER_PCT" ]; then
    if command -v docker >/dev/null; then
      docker system prune -f 2>/dev/null || true
    fi
  fi
fi

if [ "$CARGO_ENABLED" = "true" ]; then
  if command -v cargo-sweep >/dev/null; then
    cargo-sweep --time "$CARGO_KEEP_DAYS" \
      /home/diego/.cargo/target 2>/dev/null || true
  fi
fi

if [ "$NIXGC_ENABLED" = "true" ]; then
  nix-collect-garbage --delete-older-than "${NIXGC_KEEP_DAYS}d" 2>/dev/null || true
fi
