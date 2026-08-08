#!/usr/bin/env bash
echo "[wg-dns] Removing @hickoryDns@ from resolv.conf"
if command -v resolvectl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
  sudo resolvectl revert @wgInterface@ 2>/dev/null || true
else
  sudo sed -i '/^nameserver @hickoryDns@$/d' /etc/resolv.conf 2>/dev/null || true
fi
