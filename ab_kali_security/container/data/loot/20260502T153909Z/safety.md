# 🟥 Red-Team Safety Report

* When:      20260502T153909Z (UTC)
* Preset:    `tier3-senior`
* Target:    
* FSROOT:    `/host`

## TL;DR — Attacker capability matrix

| Tier | Attacker profile          | HIGH | MED | INFO | Total |
|------|---------------------------|------|-----|------|-------|
| 1 | Script kiddie / kid w/ kali | 0 | 0 | 1 | 1 |
| 2 | Junior pentester (CVE/PoC) | 0 | 2 | 1 | 3 |
| 3 | Senior pentester (privesc) | 0 | 0 | 0 | 0 |
| 4 | Expert / kernel / escape | 0 | 0 | 2 | 2 |

## Tier 1 — Script kiddie sees & exploits

### 🔵 **INFO** — 4 non-loopback TCP listeners on host
Confirm each one is intentional. Anything bound to 0.0.0.0 is reachable to whoever shares this LAN.
Evidence: `/loot/20260502T153909Z/local/tier1/ss-listen/ss-listen.txt`

## Tier 2 — Junior pentester (CVE matching, automated)

### 🟠 **MEDIUM** — AP `Be Happy Hostels 5G` advertises WPS
Pixie-Dust + Reaver can recover WPA2 PSK in minutes/hours. As a guest you can't disable on the AP — use a VPN.
Evidence: `/loot/20260502T153909Z/local/wifi/iw-survey/wifi-survey.txt`

### 🟠 **MEDIUM** — nmap-vulners flagged 10 CVE references on localhost services
Inspect /loot/20260502T153909Z/local/tier2/nmap-localhost-vuln/nmap-localhost.stdout. Each CVE = junior pentester googles + runs the public PoC.
Evidence: `/loot/20260502T153909Z/local/tier2/nmap-localhost-vuln/nmap-localhost.stdout`

### 🔵 **INFO** — searchsploit found 2 public exploits matching kernel keyword
Most are old/historical, some current. Worth a quick eyeball: `searchsploit linux kernel $(uname -r)`
Evidence: `/loot/20260502T153909Z/local/tier2/searchsploit-kernel/searchsploit.json`

## Tier 4 — Expert / kernel / container escape

### 🔵 **INFO** — Kernel side-channel mitigations: 5 active
Spectre/Meltdown/L1TF/MDS family. `cat /loot/20260502T153909Z/local/tier2/kernel-mitigations/mitigations.txt` for the full breakdown.
Evidence: `/loot/20260502T153909Z/local/tier2/kernel-mitigations/mitigations.txt`

### 🔵 **INFO** — 297 kernel modules loaded
Each loaded module is potential attack surface. Compare to baseline / pkg-list.
Evidence: `/loot/20260502T153909Z/local/tier3/loaded-modules/lsmod.txt`

## Raw loot

`/loot/20260502T153909Z`

Generic per-tool log: [`report.md`](report.md)
