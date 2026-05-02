#!/usr/bin/env bash
# Passive Wi-Fi survey (no monitor mode, no injection).
# Per interface: link state, encryption of current AP, brief scan of nearby APs.
# Runs in the kali scanner container with host network + NET_ADMIN.
set -uo pipefail

run() { echo "─── $* ───"; "$@" 2>&1 || true; echo; }

run iw dev
run rfkill list
run iwconfig

mapfile -t ifaces < <(iw dev 2>/dev/null | awk '/Interface/{print $2}')
[[ ${#ifaces[@]} -eq 0 ]] && { echo "(no wireless interfaces found)"; exit 0; }

for i in "${ifaces[@]}"; do
    echo "═══════════════════════════════════════════════════════════"
    echo " INTERFACE: $i"
    echo "═══════════════════════════════════════════════════════════"
    run iw "$i" link
    run iw "$i" info
    echo "─── nearby APs (passive scan) ───"
    iw "$i" scan 2>/dev/null \
      | grep -E '^BSS |SSID:|signal:|freq:|RSN:|WPA:|WPS:|capability:|Authentication suites|Pairwise ciphers|Group cipher' \
      | head -400 || true
    echo
done
