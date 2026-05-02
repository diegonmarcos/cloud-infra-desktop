# Scan Report — 20260502T152441Z

* Preset:    `safety-report`
* Target:    ``
* Budget:    600s
* FSROOT:    `/host`
* Wallclock: 2s

## Summary

| OK | Ignored | Failed | Total |
|---|---|---|---|
| 18 | 2 | 0 | 20 |

## Jobs

| Domain | Category | Tool | Exit | Duration | Output |
|---|---|---|---|---|---|
| local | system | uname | 0 | 0s | /loot/20260502T152441Z/local/system/uname |
| local | system | lsb-release | 0 | 0s | /loot/20260502T152441Z/local/system/lsb-release |
| local | users | passwd-host | 0 | 0s | /loot/20260502T152441Z/local/users/passwd-host |
| local | users | sshd-config | 1 ⚠️ | 0s | /loot/20260502T152441Z/local/users/sshd-config |
| local | users | sudoers | 0 | 0s | /loot/20260502T152441Z/local/users/sudoers |
| local | users | shadow-perms | 0 | 0s | /loot/20260502T152441Z/local/users/shadow-perms |
| local | net-state | ss-listen | 0 | 0s | /loot/20260502T152441Z/local/net-state/ss-listen |
| local | net-state | ip-addr | 0 | 0s | /loot/20260502T152441Z/local/net-state/ip-addr |
| local | net-state | ip-route | 0 | 0s | /loot/20260502T152441Z/local/net-state/ip-route |
| local | net-state | iptables-save | 0 | 0s | /loot/20260502T152441Z/local/net-state/iptables-save |
| local | procs | ps-aux | 0 | 0s | /loot/20260502T152441Z/local/procs/ps-aux |
| local | fs | suid | 0 | 0s | /loot/20260502T152441Z/local/fs/suid |
| local | fs | sgid | 0 | 0s | /loot/20260502T152441Z/local/fs/sgid |
| local | fs | world-writable | 0 | 0s | /loot/20260502T152441Z/local/fs/world-writable |
| local | wifi | iw-survey | 0 | 2s | /loot/20260502T152441Z/local/wifi/iw-survey |
| local | dns-arp | arp-table | 0 | 0s | /loot/20260502T152441Z/local/dns-arp/arp-table |
| local | dns-arp | resolv-conf | 0 | 0s | /loot/20260502T152441Z/local/dns-arp/resolv-conf |
| local | dns-arp | hosts-file | 1 ⚠️ | 0s | /loot/20260502T152441Z/local/dns-arp/hosts-file |
| local | auth-state | who | 0 | 0s | /loot/20260502T152441Z/local/auth-state/who |
| local | auth-state | auth-failures | 0 | 0s | /loot/20260502T152441Z/local/auth-state/auth-failures |
