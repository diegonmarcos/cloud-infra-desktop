# Scan Report — 20260502T163641Z

* Preset:    `tier3-senior`
* Target:    ``
* Budget:    1500s
* FSROOT:    `/host`
* Wallclock: 145s

## Summary

| OK | Ignored | Failed | Total |
|---|---|---|---|
| 13 | 2 | 0 | 15 |

## Jobs

| Domain | Category | Tool | Exit | Duration | Output |
|---|---|---|---|---|---|
| local | wifi | iw-survey | 0 | 2s | /loot/20260502T163641Z/local/wifi/iw-survey |
| local | tier1 | iw-survey | 0 | 2s | /loot/20260502T163641Z/local/tier1/iw-survey |
| local | tier1 | sshd-config | 1 ⚠️ | 0s | /loot/20260502T163641Z/local/tier1/sshd-config |
| local | tier1 | shadow-perms | 0 | 0s | /loot/20260502T163641Z/local/tier1/shadow-perms |
| local | tier1 | ss-listen | 0 | 0s | /loot/20260502T163641Z/local/tier1/ss-listen |
| local | tier1 | kernel-version | 0 | 0s | /loot/20260502T163641Z/local/tier1/kernel-version |
| local | tier2 | nmap-localhost-vuln | 0 | 11s | /loot/20260502T163641Z/local/tier2/nmap-localhost-vuln |
| local | tier2 | linux-exploit-suggester | 0 | 0s | /loot/20260502T163641Z/local/tier2/linux-exploit-suggester |
| local | tier2 | searchsploit-kernel | 0 | 2s | /loot/20260502T163641Z/local/tier2/searchsploit-kernel |
| local | tier2 | kernel-mitigations | 0 | 0s | /loot/20260502T163641Z/local/tier2/kernel-mitigations |
| local | tier3 | linpeas-quick | 0 | 0s | /loot/20260502T163641Z/local/tier3/linpeas-quick |
| local | tier3 | chkrootkit | 0 | 2s | /loot/20260502T163641Z/local/tier3/chkrootkit |
| local | tier3 | pspy-snapshot | 0 | 12s | /loot/20260502T163641Z/local/tier3/pspy-snapshot |
| local | tier3 | loaded-modules | 0 | 0s | /loot/20260502T163641Z/local/tier3/loaded-modules |
| local | tier3 | trivy-host | 1 ⚠️ | 114s | /loot/20260502T163641Z/local/tier3/trivy-host |
