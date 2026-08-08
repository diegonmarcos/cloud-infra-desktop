#!/usr/bin/env bash
# Wait for wg0 interface to exist (max 10s)
for i in $(seq 1 10); do
  if ip link show @wgInterface@ >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! ip link show @wgInterface@ >/dev/null 2>&1; then
  echo "[wg-dns] @wgInterface@ not found — skipping DNS config"
  exit 0
fi

echo "[wg-dns] Adding @hickoryDns@ to resolv.conf for .app names"

# Method 1: systemd-resolved (if available)
if command -v resolvectl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
  echo "[wg-dns] Using systemd-resolved split DNS"
  sudo resolvectl dns @wgInterface@ @hickoryDns@
  sudo resolvectl domain @wgInterface@ @wgDomains@
  sudo resolvectl default-route @wgInterface@ false
else
  # Method 2: Direct resolv.conf prepend (resolvconf/NetworkManager systems)
  echo "[wg-dns] Using resolv.conf prepend (no systemd-resolved)"
  if ! grep -q "@hickoryDns@" /etc/resolv.conf 2>/dev/null; then
    # Prepend Hickory as first nameserver
    sudo sed -i '1s/^/nameserver @hickoryDns@\n/' /etc/resolv.conf
    echo "[wg-dns] Added nameserver @hickoryDns@ to /etc/resolv.conf"
  else
    echo "[wg-dns] @hickoryDns@ already in resolv.conf"
  fi
fi

echo "[wg-dns] Verifying: dig @@hickoryDns@ authelia.app"
dig @@hickoryDns@ +short authelia.app 2>/dev/null || echo "(hickory not reachable — wg0 may need time)"
echo "[wg-dns] Done"
