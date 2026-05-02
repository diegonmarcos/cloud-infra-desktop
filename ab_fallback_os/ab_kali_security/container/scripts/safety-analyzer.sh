#!/usr/bin/env bash
# Red-team safety analyzer. Reads loot/<run>/* and emits safety.md with
# tier-graded findings (1=script-kiddie .. 4=expert/kernel) and a TL;DR table.
# Each finding: tier (1-4), severity (HIGH|MEDIUM|INFO), title, recommendation.
set -uo pipefail
[[ "${VERBOSE:-0}" == "1" ]] && set -x
log() { printf '\033[36m[%s safety]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

manifest="${1:?need manifest.json}"
[[ -r "$manifest" ]] || { echo "no such manifest: $manifest" >&2; exit 1; }
RUN="${manifest%/*}"
out="$RUN/safety.md"

ts="$(jq -r '.timestamp' "$manifest")"
preset="$(jq -r '.preset'  "$manifest")"
target="$(jq -r '.target // "(local-host)"' "$manifest")"
fsroot="$(jq -r '.fsroot' "$manifest")"

find_artifact() { find "$RUN" -path "*/$1/$2" -print -quit 2>/dev/null; }
have() { [[ -s "$1" ]]; }

# findings storage: each line = "TIER|SEVERITY|TITLE|RECOMMENDATION|EVIDENCE"
findings=()
add() { findings+=("$1|$2|$3|$4|${5:-}"); }

# ─────────── TIER 1 — script kiddie / passive recon / off-the-shelf ──────────
WIFI=$(find_artifact iw-survey wifi-survey.txt)
if have "$WIFI"; then
    cur_ssid=$(grep -m1 -E '^[[:space:]]+ssid ' "$WIFI" | sed -E 's/^[[:space:]]+ssid[[:space:]]+//')
    [[ -z "$cur_ssid" ]] && cur_ssid="(unknown)"

    enc_facts=$(awk -v target="$cur_ssid" '
      function flush(){ if(in_block){ tag=(ssid==target?"CUR":"OTH"); printf "%s|%s|%s|rsn=%d wpa=%d wep=%d wps=%d privacy=%d\n", tag,bss,ssid,rsn,wpa,wep,wps,priv } }
      /^BSS [0-9a-f:]+/                    { flush(); in_block=1; bss=$2; ssid=""; rsn=0; wpa=0; wep=0; wps=0; priv=0; next }
      /^[ \t]+SSID:/                        { sub(/^[ \t]+SSID:[ \t]*/,""); ssid=$0; next }
      /^[ \t]+RSN:/                         { rsn=1; next }
      /^[ \t]+WPA:/                         { wpa=1; next }
      /^[ \t]+WPS:/                         { wps=1; next }
      /^[ \t]+capability:.*Privacy/         { priv=1; next }
      /WEP/                                 { wep=1; next }
      END { flush() }' "$WIFI")
    cur_line=$(printf '%s\n' "$enc_facts" | awk -F'|' '$1=="CUR"' | head -1)
    if [[ -n "$cur_line" ]]; then
        rsn=$(echo "$cur_line"  | grep -oE 'rsn=[01]'    | cut -d= -f2)
        wpa=$(echo "$cur_line"  | grep -oE 'wpa=[01]'    | cut -d= -f2)
        wep=$(echo "$cur_line"  | grep -oE 'wep=[01]'    | cut -d= -f2)
        wps=$(echo "$cur_line"  | grep -oE 'wps=[01]'    | cut -d= -f2)

        if (( rsn == 0 && wpa == 0 && wep == 0 )); then
            add 1 HIGH "Connected AP \`$cur_ssid\` is OPEN (no encryption)" \
                "Move to a WPA2/WPA3 network. Anyone passively sniffing 802.11 frames sees your traffic." "$WIFI"
        elif (( wep == 1 )); then
            add 1 HIGH "Connected AP \`$cur_ssid\` uses WEP (broken since 2007)" \
                "Switch to a WPA2/WPA3 network. WEP can be cracked in minutes with aircrack-ng." "$WIFI"
        elif (( wpa == 1 && rsn == 0 )); then
            add 1 HIGH "Connected AP \`$cur_ssid\` uses WPA1/TKIP only" \
                "WPA1 is broken. Use WPA2-CCMP or WPA3 only." "$WIFI"
        fi
        (( wps == 1 )) && add 2 MEDIUM "AP \`$cur_ssid\` advertises WPS" \
            "Pixie-Dust + Reaver can recover WPA2 PSK in minutes/hours. As a guest you can't disable on the AP — use a VPN." "$WIFI"

        bssids=$(printf '%s\n' "$enc_facts" | awk -F'|' -v s="$cur_ssid" '$3==s {print $2}' | sort -u | wc -l)
        if (( bssids > 1 )); then
            add 2 MEDIUM "SSID \`$cur_ssid\` broadcast by $bssids BSSIDs" \
                "Could be normal mesh/extender — OR an evil twin. Check BSSIDs match the legitimate AP's MAC range." "$WIFI"
        fi
    fi

    open_count=$(printf '%s\n' "$enc_facts" | awk -F'|' '$1=="OTH" && $4 ~ /rsn=0/ && $4 ~ /wpa=0/ && $4 ~ /wep=0/ && $4 ~ /privacy=0/ && $3!="" { print $3 }' | sort -u | wc -l)
    (( open_count > 0 )) && add 1 INFO "$open_count open networks visible nearby" \
        "Don't auto-connect to open APs (deauth + evil-twin trick). Disable 'auto-join open networks'." "$WIFI"
fi

SSHD=$(find_artifact sshd-config sshd_config.txt)
if have "$SSHD"; then
    grep -qE '^\s*PermitRootLogin\s+yes' "$SSHD"        && add 1 HIGH "sshd: PermitRootLogin yes" \
        "Disable: \`PermitRootLogin no\`. Direct root SSH = #1 brute force target." "$SSHD"
    grep -qE '^\s*PasswordAuthentication\s+yes' "$SSHD" && add 1 MEDIUM "sshd: PasswordAuthentication yes" \
        "Switch to keys-only: \`PasswordAuthentication no\`. Hydra/medusa try common passwords against any open ssh." "$SSHD"
    grep -qE '^\s*PermitEmptyPasswords\s+yes' "$SSHD"   && add 1 HIGH "sshd: PermitEmptyPasswords yes" \
        "Disable immediately: \`PermitEmptyPasswords no\`." "$SSHD"
fi

SHADOW=$(find_artifact shadow-perms shadow-perms.txt)
if have "$SHADOW"; then
    if grep -E "shadow$" "$SHADOW" | grep -qE '^[7654][7654][^0]'; then
        add 1 HIGH "/etc/shadow not 600/640" \
            "World/group readable shadow file → script kiddie reads hashes, runs hashcat. \`chmod 640 /etc/shadow\`" "$SHADOW"
    fi
fi

SS=$(find_artifact ss-listen ss-listen.txt)
if have "$SS"; then
    pub_listeners=$(awk '$1 ~ /tcp/ && $5 !~ /127\.|\[::1\]|^::1/' "$SS" | wc -l)
    (( pub_listeners > 0 )) && add 1 INFO "$pub_listeners non-loopback TCP listeners on host" \
        "Confirm each one is intentional. Anything bound to 0.0.0.0 is reachable to whoever shares this LAN." "$SS"
fi

# ─────────── TIER 2 — junior pentester / CVE-matching / banner-aware ─────────
LES=$(find_artifact linux-exploit-suggester les.txt)
if have "$LES"; then
    crit=$(grep -cE 'Possible Exploits:.*(highly probable|probable)' "$LES" || true)
    (( crit > 0 )) && add 2 HIGH "linux-exploit-suggester flagged $crit kernel-CVE matches" \
        "Update the kernel. PoC exploits exist publicly — junior pentesters know to apt install + run." "$LES"
fi

NMAP=$(find_artifact nmap-localhost-vuln nmap-localhost.stdout)
if have "$NMAP"; then
    cves=$(grep -cE 'CVE-[0-9]{4}-[0-9]+' "$NMAP" || true)
    (( cves > 0 )) && add 2 MEDIUM "nmap-vulners flagged $cves CVE references on localhost services" \
        "Inspect $NMAP. Each CVE = junior pentester googles + runs the public PoC." "$NMAP"
fi

SE=$(find_artifact searchsploit-kernel searchsploit.json)
if have "$SE"; then
    n=$(jq -r '.RESULTS_EXPLOIT | length' "$SE" 2>/dev/null || echo 0)
    (( n > 0 )) && add 2 INFO "searchsploit found $n public exploits matching kernel keyword" \
        "Most are old/historical, some current. Worth a quick eyeball: \`searchsploit linux kernel \$(uname -r)\`" "$SE"
fi

# ─────────── TIER 3 — senior pentester / linpeas full / privesc ──────────────
LP=$(find_artifact linpeas-quick linpeas.txt)
if have "$LP"; then
    # linpeas marks high-confidence findings with "[+]" and red ANSI; counts may be noisy.
    interesting=$(grep -cE '^\s*\[\+\]' "$LP" || true)
    (( interesting > 50 )) && add 3 MEDIUM "linpeas flagged $interesting potentially-interesting items" \
        "A senior pentester reads this top-to-bottom. Read $LP, focus on '95% PE' callouts." "$LP"
fi

CK=$(find_artifact chkrootkit chkrootkit.txt)
if have "$CK"; then
    if grep -q 'INFECTED' "$CK"; then
        add 3 HIGH "chkrootkit found INFECTED match" \
            "Investigate immediately. May be false positive — verify each line. \`grep INFECTED $CK\`" "$CK"
    fi
fi

TRIV=$(find_artifact trivy-host trivy.json)
if have "$TRIV"; then
    high=$(jq -r '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$TRIV" 2>/dev/null || echo 0)
    crit=$(jq -r '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$TRIV" 2>/dev/null || echo 0)
    if (( crit > 0 )); then
        add 3 HIGH "Trivy: $crit CRITICAL package CVEs on host" \
            "Run \`apt upgrade\` / \`nix-channel --update && switch\`. List: \`jq '.Results[].Vulnerabilities[]|select(.Severity==\"CRITICAL\")|.VulnerabilityID' $TRIV\`" "$TRIV"
    elif (( high > 0 )); then
        add 3 MEDIUM "Trivy: $high HIGH package CVEs on host" \
            "Patch backlog. Worth a sweep on next maintenance window." "$TRIV"
    fi
fi

# ─────────── TIER 4 — expert / kernel-level / container escape ───────────────
MIT=$(find_artifact kernel-mitigations mitigations.txt)
if have "$MIT"; then
    vulnerable=$(grep -cE '= Vulnerable' "$MIT" || true)
    if (( vulnerable > 0 )); then
        add 4 HIGH "$vulnerable CPU side-channel mitigations marked Vulnerable" \
            "Likely needs CPU microcode update + kernel boot params. \`grep Vulnerable $MIT\`" "$MIT"
    fi
    mitigated=$(grep -cE '= Mitigation' "$MIT" || true)
    add 4 INFO "Kernel side-channel mitigations: $mitigated active" \
        "Spectre/Meltdown/L1TF/MDS family. \`cat $MIT\` for the full breakdown." "$MIT"
fi

DOCK=$(find_artifact docker-escape-check docker-escape.txt)
if have "$DOCK"; then
    if grep -q 'privileged=true' "$DOCK"; then
        add 4 HIGH "Privileged Docker container(s) running on host" \
            "Container escape = root on host. Audit each privileged container; remove --privileged." "$DOCK"
    fi
    if grep -qE 'docker.sock.*srw' "$DOCK"; then
        add 4 INFO "Docker socket exposed (default)" \
            "Anyone in 'docker' group = root via container mount of /. Restrict docker group membership." "$DOCK"
    fi
fi

LSMOD=$(find_artifact loaded-modules lsmod.txt)
if have "$LSMOD"; then
    nmods=$(wc -l < "$LSMOD")
    add 4 INFO "$nmods kernel modules loaded" \
        "Each loaded module is potential attack surface. Compare to baseline / pkg-list." "$LSMOD"
fi

# ─── ACTIVELY-FIRED EXPLOIT RESULTS (category=exploit, only against self) ────
NUC=$(find_artifact nuclei-localhost nuclei.jsonl)
if have "$NUC"; then
    crit=$(grep -cE '"severity":"(high|critical)"' "$NUC" 2>/dev/null || true)
    if (( crit > 0 )); then
        add 2 HIGH "🎯 nuclei FIRED on localhost — $crit HIGH/CRITICAL hits" \
            "Nuclei templates ACTUALLY matched. \`jq '.info | {name,severity}' $NUC\`. These are real exploitable findings on your own services." "$NUC"
    else
        add 2 INFO "🎯 nuclei fired on localhost — no HIGH/CRITICAL templates matched" \
            "Active web-app vuln scan against own services found nothing serious." "$NUC"
    fi
fi

NIK=$(find_artifact nikto-localhost nikto.json)
if have "$NIK"; then
    findings_n=$(jq -r '[.vulnerabilities[]?] | length' "$NIK" 2>/dev/null || echo 0)
    if (( findings_n > 0 )); then
        add 2 MEDIUM "🎯 nikto FIRED on localhost — $findings_n web-app findings" \
            "\`jq '.vulnerabilities[]|.msg' $NIK\` — review each. Nikto fires noisy but covers OWASP basics." "$NIK"
    fi
fi

MSF=$(find_artifact msf-check-localhost msf-check.txt)
if have "$MSF"; then
    vuln=$(grep -cE '\[\+\].*Vulnerable|appears to be vulnerable' "$MSF" 2>/dev/null || true)
    if (( vuln > 0 )); then
        add 2 HIGH "🎯 metasploit FIRED on localhost — $vuln 'Vulnerable' hits" \
            "Metasploit aux scanners actively probed and got positive responses. \`grep -A2 Vulnerable $MSF\`" "$MSF"
    else
        add 2 INFO "🎯 metasploit fired on localhost — no vulnerable matches from auxiliary scanners" \
            "ssh_version, http_version, openssl_heartbleed all clean." "$MSF"
    fi
fi

LPF=$(find_artifact linpeas-full-fired linpeas-full.txt)
if have "$LPF"; then
    pe95=$(grep -cE '95%|HIGHLY|VULN' "$LPF" || true)
    if (( pe95 > 0 )); then
        add 3 HIGH "🎯 linpeas FULL flagged $pe95 high-confidence priv-esc paths" \
            "Real attacker would walk these top-down. \`grep -E '95%|HIGHLY|VULN' $LPF\`" "$LPF"
    fi
fi

LYN=$(find_artifact lynis-full lynis.dat)
if have "$LYN"; then
    score=$(grep -E '^hardening_index=' "$LYN" 2>/dev/null | cut -d= -f2)
    warn=$(grep -cE '^warning\[\]=' "$LYN" 2>/dev/null || true)
    sugg=$(grep -cE '^suggestion\[\]=' "$LYN" 2>/dev/null || true)
    [[ -n "$score" ]] && add 3 INFO "Lynis hardening index: **$score / 100**" \
        "Warnings: $warn. Suggestions: $sugg. See lynis.dat for details." "$LYN"
    if (( warn > 0 )); then
        add 3 MEDIUM "Lynis: $warn warnings on host hardening" \
            "Each warning = a senior pentester's checklist item. \`grep ^warning $LYN\`" "$LYN"
    fi
fi

RKH=$(find_artifact rkhunter-full rkhunter.log)
if have "$RKH"; then
    warn_rkh=$(grep -cE 'Warning' "$RKH" 2>/dev/null || true)
    if (( warn_rkh > 0 )); then
        add 3 MEDIUM "rkhunter raised $warn_rkh warnings" \
            "Most are tuning-needed FPs (modified system files); review each. \`grep Warning $RKH\`" "$RKH"
    fi
fi

# Skipped exploit tools (target was external recon-only)
skipped_n=$(jq '[.jobs[] | select(.skipped==true)] | length' "$manifest" 2>/dev/null || echo 0)
if (( skipped_n > 0 )); then
    add 1 INFO "$skipped_n exploit-class tools were SKIPPED" \
        "Target wasn't in self_assets — auth gate prevented active exploitation. \`jq '.jobs[]|select(.skipped)' $manifest\`" "$manifest"
fi

# ─── TL;DR matrix ─────────────────────────────────────────────────────────────
count_tier_sev() {
    local tier="$1" sev="$2"
    printf '%s\n' "${findings[@]}" | awk -F'|' -v t="$tier" -v s="$sev" '$1==t && $2==s' | wc -l
}

# ─── render ───────────────────────────────────────────────────────────────────
{
    printf "# 🟥 Red-Team Safety Report\n\n"
    printf "* When:      %s (UTC)\n"  "$ts"
    printf "* Preset:    \`%s\`\n"     "$preset"
    printf "* Target:    %s\n"         "$target"
    printf "* FSROOT:    \`%s\`\n\n"    "$fsroot"

    printf "## TL;DR — Attacker capability matrix\n\n"
    printf "| Tier | Attacker profile          | HIGH | MED | INFO | Total |\n"
    printf "|------|---------------------------|------|-----|------|-------|\n"
    for t in 1 2 3 4; do
        case "$t" in
            1) name="Script kiddie / kid w/ kali" ;;
            2) name="Junior pentester (CVE/PoC)"  ;;
            3) name="Senior pentester (privesc)"  ;;
            4) name="Expert / kernel / escape"    ;;
        esac
        h=$(count_tier_sev "$t" HIGH); m=$(count_tier_sev "$t" MEDIUM); i=$(count_tier_sev "$t" INFO)
        total=$(( h + m + i ))
        printf "| %s | %s | %s | %s | %s | %s |\n" "$t" "$name" "$h" "$m" "$i" "$total"
    done
    printf "\n"

    for t in 1 2 3 4; do
        rows=$(printf '%s\n' "${findings[@]}" | awk -F'|' -v t="$t" '$1==t')
        [[ -z "$rows" ]] && continue
        case "$t" in
            1) printf "## Tier 1 — Script kiddie sees & exploits\n\n" ;;
            2) printf "## Tier 2 — Junior pentester (CVE matching, automated)\n\n" ;;
            3) printf "## Tier 3 — Senior pentester (privesc + post-exploit)\n\n" ;;
            4) printf "## Tier 4 — Expert / kernel / container escape\n\n" ;;
        esac
        while IFS='|' read -r tier sev title rec evidence; do
            case "$sev" in
                HIGH)   icon="🔴" ;;
                MEDIUM) icon="🟠" ;;
                INFO)   icon="🔵" ;;
                *)      icon="•"  ;;
            esac
            printf "### %s **%s** — %s\n" "$icon" "$sev" "$title"
            printf "%s\n"  "$rec"
            [[ -n "$evidence" ]] && printf "Evidence: \`%s\`\n" "$evidence"
            printf "\n"
        done <<< "$rows"
    done

    printf "## Raw loot\n\n\`%s\`\n\n" "$RUN"
    printf "Generic per-tool log: [\`report.md\`](report.md)\n"
} > "$out"

log "wrote $out — $(printf '%s\n' "${findings[@]}" | wc -l) findings"
