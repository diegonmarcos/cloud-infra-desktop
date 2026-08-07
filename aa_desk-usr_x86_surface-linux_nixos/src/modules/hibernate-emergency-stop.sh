#!/usr/bin/env bash
# hibernate-emergency-stop.sh — emergency cancel command, installed in
# $PATH. Stops systemd-hibernate.service AND the battery-watchdog that could
# re-trigger it. See configuration_pre-hibernate-warning.nix.
set -u

systemctl stop systemd-hibernate.service 2>&1 || true
systemctl reset-failed systemd-hibernate.service 2>&1 || true
systemctl stop battery-watchdog.timer battery-watchdog.service 2>&1 || true
logger -t hibernate-cancel -p daemon.warning \
  "EMERGENCY-STOP: hibernate cancelled + watchdog stopped by $(whoami)"
echo "[hibernate-emergency-stop] systemd-hibernate.service + battery-watchdog stopped."
systemctl is-active systemd-hibernate.service battery-watchdog.timer || true
