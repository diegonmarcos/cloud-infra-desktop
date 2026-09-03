#!/usr/bin/env bash
# ============================================================================
# bootstrap-sshd.sh — emergency Termux SSHD bootstrap
# ============================================================================
# Use ONLY when home-manager isn't applied yet (or shell PATH is broken) and
# you need an SSH session into the phone to run build.sh remotely.
#
# Reads pubkeys from src/modules/data/authorized-keys.json (same source of
# truth as sshd.nix), generates a host key if missing, and starts sshd
# foreground-detached on port 8022.
#
# Run via:
#   nix-shell -p openssh jq --run "bash $HOME/git/cloud-infra-desktop/bb_flakes_termux/bootstrap-sshd.sh"
#
# After SSH-ing in, run the real engine to make this permanent:
#   ~/git/cloud-infra-desktop/bb_flakes_termux/build.sh
# ============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_JSON="$SCRIPT_DIR/src/modules/data/authorized-keys.json"
PID_FILE="$HOME/.cache/sshd.pid"
LOG_FILE="$HOME/.cache/sshd.log"

[ -f "$KEYS_JSON" ] || { echo "FATAL: $KEYS_JSON missing — git pull first"; exit 1; }
# OpenSSH re-executes its own binary via argv[0] on every connection; a bare
# `sshd` (relative name off $PATH) makes argv[0] relative and sshd refuses with
# "re-exec requires execution with an absolute path". Resolve the absolute
# store path up front and invoke THAT below.
SSHD_BIN="$(command -v sshd)" || { echo "FATAL: sshd missing — re-run under: nix-shell -p openssh jq"; exit 1; }
SSHD_BIN="$(readlink -f "$SSHD_BIN" 2>/dev/null || echo "$SSHD_BIN")"
command -v ssh-keygen >/dev/null || { echo "FATAL: ssh-keygen missing"; exit 1; }
command -v jq         >/dev/null || { echo "FATAL: jq missing — re-run under: nix-shell -p openssh jq"; exit 1; }

mkdir -p "$HOME/.ssh" "$HOME/.cache"
chmod 700 "$HOME/.ssh"

if [ ! -f "$HOME/.ssh/ssh_host_ed25519_key" ]; then
  ssh-keygen -t ed25519 -f "$HOME/.ssh/ssh_host_ed25519_key" -N "" -q
  echo "[bootstrap-sshd] generated host key"
fi

jq -r '.trusted_pubkeys[]' "$KEYS_JSON" > "$HOME/.ssh/authorized_keys.tmp"
mv "$HOME/.ssh/authorized_keys.tmp" "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys" "$HOME/.ssh/ssh_host_ed25519_key"
echo "[bootstrap-sshd] seeded authorized_keys ($(wc -l < "$HOME/.ssh/authorized_keys") keys)"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  pid=$(cat "$PID_FILE")
  echo "[bootstrap-sshd] sshd already running (PID $pid) on :8022"
  exit 0
fi
rm -f "$PID_FILE"

"$SSHD_BIN" -p 8022 \
  -o "PidFile=$PID_FILE" \
  -o "HostKey=$HOME/.ssh/ssh_host_ed25519_key" \
  -o "PasswordAuthentication=no" \
  -o "PubkeyAuthentication=yes" \
  -E "$LOG_FILE"

sleep 1
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "[bootstrap-sshd] sshd up on :8022 (PID $(cat "$PID_FILE"))"
else
  echo "[bootstrap-sshd] FAILED — last log:"
  tail -20 "$LOG_FILE" 2>/dev/null || true
  exit 1
fi
