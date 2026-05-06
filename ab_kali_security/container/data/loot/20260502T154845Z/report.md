# Scan Report — 20260502T154845Z

* Preset:    `fired-self`
* Target:    ``
* Budget:    2400s
* FSROOT:    `/host`
* Wallclock: 467s

## Summary

| OK | Ignored | Failed | Total |
|---|---|---|---|
| 21 | 3 | 0 | 24 |

## Jobs

| Domain | Category | Tool | Exit | Duration | Output |
|---|---|---|---|---|---|
| local | wifi | iw-survey | 0 | 2s | /loot/20260502T154845Z/local/wifi/iw-survey |
| local | tier1 | iw-survey | 0 | 2s | /loot/20260502T154845Z/local/tier1/iw-survey |
| local | tier1 | sshd-config | 1 ⚠️ | 0s | /loot/20260502T154845Z/local/tier1/sshd-config |
| local | tier1 | shadow-perms | 0 | 0s | /loot/20260502T154845Z/local/tier1/shadow-perms |
| local | tier1 | ss-listen | 0 | 0s | /loot/20260502T154845Z/local/tier1/ss-listen |
| local | tier1 | kernel-version | 0 | 0s | /loot/20260502T154845Z/local/tier1/kernel-version |
| local | tier2 | nmap-localhost-vuln | 0 | 12s | /loot/20260502T154845Z/local/tier2/nmap-localhost-vuln |
| local | tier2 | linux-exploit-suggester | 0 | 0s | /loot/20260502T154845Z/local/tier2/linux-exploit-suggester |
| local | tier2 | searchsploit-kernel | 0 | 1s | /loot/20260502T154845Z/local/tier2/searchsploit-kernel |
| local | tier2 | kernel-mitigations | 0 | 0s | /loot/20260502T154845Z/local/tier2/kernel-mitigations |
| local | tier3 | linpeas-quick | 0 | 0s | /loot/20260502T154845Z/local/tier3/linpeas-quick |
| local | tier3 | chkrootkit | 0 | 2s | /loot/20260502T154845Z/local/tier3/chkrootkit |
| local | tier3 | pspy-snapshot | 0 | 13s | /loot/20260502T154845Z/local/tier3/pspy-snapshot |
| local | tier3 | loaded-modules | 0 | 0s | /loot/20260502T154845Z/local/tier3/loaded-modules |
| local | tier3 | trivy-host | 1 ⚠️ | 127s | /loot/20260502T154845Z/local/tier3/trivy-host |
| local | tier4 | docker-escape-check | 0 | 0s | /loot/20260502T154845Z/local/tier4/docker-escape-check |
| local | tier4 | kernel-mitigations | 0 | 0s | /loot/20260502T154845Z/local/tier4/kernel-mitigations |
| local | tier4 | loaded-modules | 0 | 0s | /loot/20260502T154845Z/local/tier4/loaded-modules |
| local | exploit-self | nuclei-localhost | 0 | 65s | /loot/20260502T154845Z/local/exploit-self/nuclei-localhost |
| local | exploit-self | nikto-localhost | 0 | 0s | /loot/20260502T154845Z/local/exploit-self/nikto-localhost |
| local | exploit-self | msf-check-localhost | 0 | 11s | /loot/20260502T154845Z/local/exploit-self/msf-check-localhost |
| local | exploit-self | linpeas-full-fired | 0 | 0s | /loot/20260502T154845Z/local/exploit-self/linpeas-full-fired |
| local | exploit-self | lynis-full | 0 | 121s | /loot/20260502T154845Z/local/exploit-self/lynis-full |
| local | exploit-self | rkhunter-full | 1 ⚠️ | 111s | /loot/20260502T154845Z/local/exploit-self/rkhunter-full |
