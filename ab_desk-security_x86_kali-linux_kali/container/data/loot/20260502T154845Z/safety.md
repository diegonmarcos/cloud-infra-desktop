# 🟥 Red-Team Safety Report

* When:      20260502T154845Z (UTC)
* Preset:    `fired-self`
* Target:    
* FSROOT:    `/host`

## TL;DR — Attacker capability matrix

| Tier | Attacker profile          | HIGH | MED | INFO | Total |
|------|---------------------------|------|-----|------|-------|
| 1 | Script kiddie / kid w/ kali | 0 | 0 | 1 | 1 |
| 2 | Junior pentester (CVE/PoC) | 0 | 2 | 2 | 4 |
| 3 | Senior pentester (privesc) | 0 | 2 | 1 | 3 |
| 4 | Expert / kernel / escape | 0 | 0 | 2 | 2 |

## Tier 1 — Script kiddie sees & exploits

### 🔵 **INFO** — 4 non-loopback TCP listeners on host
Confirm each one is intentional. Anything bound to 0.0.0.0 is reachable to whoever shares this LAN.
Evidence: `/home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/tier1/ss-listen/ss-listen.txt`

## Tier 2 — Junior pentester (CVE matching, automated)

### 🟠 **MEDIUM** — AP `Be Happy Hostels 5G` advertises WPS
Pixie-Dust + Reaver can recover WPA2 PSK in minutes/hours. As a guest you can't disable on the AP — use a VPN.
Evidence: `/home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/wifi/iw-survey/wifi-survey.txt`

### 🟠 **MEDIUM** — nmap-vulners flagged 10 CVE references on localhost services
Inspect /home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/tier2/nmap-localhost-vuln/nmap-localhost.stdout. Each CVE = junior pentester googles + runs the public PoC.
Evidence: `/home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/tier2/nmap-localhost-vuln/nmap-localhost.stdout`

### 🔵 **INFO** — searchsploit found 2 public exploits matching kernel keyword
Most are old/historical, some current. Worth a quick eyeball: `searchsploit linux kernel $(uname -r)`
Evidence: `/home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/tier2/searchsploit-kernel/searchsploit.json`

### 🔵 **INFO** — 🎯 metasploit fired on localhost — no vulnerable matches from auxiliary scanners
ssh_version, http_version, openssl_heartbleed all clean.
Evidence: `/home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/exploit-self/msf-check-localhost/msf-check.txt`

## Tier 3 — Senior pentester (privesc + post-exploit)

### 🔵 **INFO** — Lynis hardening index: **65 / 100**
Warnings: 1. Suggestions: 56. See lynis.dat for details.
Evidence: `/home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/exploit-self/lynis-full/lynis.dat`

### 🟠 **MEDIUM** — Lynis: 1 warnings on host hardening
Each warning = a senior pentester's checklist item. `grep ^warning /home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/exploit-self/lynis-full/lynis.dat`
Evidence: `/home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/exploit-self/lynis-full/lynis.dat`

### 🟠 **MEDIUM** — rkhunter raised 38 warnings
Most are tuning-needed FPs (modified system files); review each. `grep Warning /home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/exploit-self/rkhunter-full/rkhunter.log`
Evidence: `/home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/exploit-self/rkhunter-full/rkhunter.log`

## Tier 4 — Expert / kernel / container escape

### 🔵 **INFO** — Kernel side-channel mitigations: 5 active
Spectre/Meltdown/L1TF/MDS family. `cat /home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/tier2/kernel-mitigations/mitigations.txt` for the full breakdown.
Evidence: `/home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/tier2/kernel-mitigations/mitigations.txt`

### 🔵 **INFO** — 297 kernel modules loaded
Each loaded module is potential attack surface. Compare to baseline / pkg-list.
Evidence: `/home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z/local/tier3/loaded-modules/lsmod.txt`

## Raw loot

`/home/diego/git/cloud-unix/ab_fallback_os/ab_kali_security/container/data/loot/20260502T154845Z`

Generic per-tool log: [`report.md`](report.md)
