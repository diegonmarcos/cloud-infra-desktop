#!/usr/bin/env bash
# rescue-ssh-prestart.sh — one-time Dropbear host-key generation for the
# rescue-ssh.service preStart hook.
#
# Fully runtime-data-driven: the rescue port (used only in the readiness log
# line — dropbear itself is invoked with the port via ExecStart, which stays
# Nix-side unit config) is read from CONFIG_JSON
# (/etc/cloud-data/system-protection.json) via jq. Nothing is baked in by
# Nix. See configuration_system-protection.nix for how this script is wired
# (writeShellApplication + environment.etc deploy of the JSON).
#
# Built via pkgs.writeShellApplication — runtimeInputs supplies dropbear, jq.
set -u

CONFIG_JSON="${SYSTEM_PROTECTION_JSON:-/etc/cloud-data/system-protection.json}"

# Fail LOUDLY and safely if config is missing/unreadable/unparseable.
if [ ! -r "$CONFIG_JSON" ]; then
  logger -t rescue-ssh -p user.err "rescue-ssh: CONFIG MISSING/UNREADABLE at $CONFIG_JSON — refusing to run"
  echo "[rescue-ssh] FATAL: config missing/unreadable at $CONFIG_JSON" >&2
  exit 1
fi
if ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t rescue-ssh -p user.err "rescue-ssh: CONFIG UNPARSEABLE at $CONFIG_JSON — refusing to run"
  echo "[rescue-ssh] FATAL: config unparseable at $CONFIG_JSON" >&2
  exit 1
fi

RESCUE_PORT=$(jq -r '.rescue_port' "$CONFIG_JSON")

mkdir -p /etc/dropbear
if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
  dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key
  echo "[rescue-ssh] Generated ed25519 host key"
fi
echo "[rescue-ssh] Ready on port ${RESCUE_PORT}"
