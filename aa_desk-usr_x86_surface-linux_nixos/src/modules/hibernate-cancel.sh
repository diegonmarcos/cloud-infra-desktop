#!/usr/bin/env bash
# hibernate-cancel.sh — emergency cancel command, installed in $PATH. Stops
# systemd-hibernate.service. See configuration_pre-hibernate-warning.nix.
set -u

systemctl stop systemd-hibernate.service 2>&1 || true
systemctl reset-failed systemd-hibernate.service 2>&1 || true
logger -t hibernate-cancel -p daemon.warning \
  "Hibernate cancelled by $(whoami)"
echo "[hibernate-cancel] systemd-hibernate.service stopped."
systemctl is-active systemd-hibernate.service || true
