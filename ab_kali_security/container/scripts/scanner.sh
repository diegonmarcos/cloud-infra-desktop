#!/usr/bin/env bash
# Universal scan orchestrator. Reads /scans.json + /targets.json.
# Runs INSIDE the kali container under one of two profiles:
#   scanner-local   (root, /:/host:ro mounted, FSROOT=/host)
#   scanner-network (kali user, no host mount, FSROOT=/)
# Args: --preset <name>  --target <host>  --budget <secs>  [--out <ts>]
# Auth: any non-empty --target must match a pattern in /targets.json.
set -euo pipefail

# Verbose by default; opt-out with QUIET=1, full xtrace with VERBOSE=1.
[[ "${VERBOSE:-0}" == "1" ]] && set -x
if [[ "${QUIET:-0}" == "1" ]]; then
    log() { :; }
else
    log() { printf '\033[36m[%s scanner]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fi

SCANS=/scans.json
TARGETS=/targets.json
LOOT_ROOT="$(jq -r '.loot_root // "/loot"' "$SCANS")"
FSROOT="${FSROOT:-/}"

preset=""; target=""; budget=600; out_ts=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --preset) preset="$2"; shift 2 ;;
        --target) target="$2"; shift 2 ;;
        --budget) budget="$2"; shift 2 ;;
        --out)    out_ts="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: scanner.sh --preset <name> [--target <host>] [--budget <secs>]"
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$preset" ]] || { echo "ERROR: --preset required"  >&2; exit 2; }
jq -e --arg p "$preset" '.presets[$p]' "$SCANS" >/dev/null \
    || { echo "ERROR: preset '$preset' not in $SCANS" >&2; exit 2; }

# ─── authorization gate (v2: per-block exploitation policy) ──────────────────
# Returns the exploitation policy ("allowed" | "recon-only") for a target,
# or empty string if the target is not in any authorized block.
classify_target() {
    local host="$1"
    host="${host##*@}"; host="${host%%/*}"; host="${host##*://}"; host="${host%%:*}"

    local block
    for block in self_assets external_recon_only; do
        local exploit; exploit="$(jq -r --arg b "$block" '.[$b].exploitation // empty' "$TARGETS")"
        [[ -z "$exploit" ]] && continue

        # hostnames (literal + *.wildcard)
        while IFS= read -r pat; do
            if [[ "$pat" == "$host" ]]; then echo "$exploit"; return 0; fi
            if [[ "$pat" == \*.* ]] && [[ "$host" == "${pat#\*.}" || "$host" == *."${pat#\*.}" ]]; then
                echo "$exploit"; return 0
            fi
        done < <(jq -r --arg b "$block" '.[$b].hostnames[]?' "$TARGETS")

        # CIDR (loopback + private)
        if [[ "$host" =~ ^[0-9a-fA-F:.]+(/[0-9]+)?$ ]]; then
            local cidrs; cidrs="$(jq -r --arg b "$block" '.[$b].loopback[]?,.[$b].private_cidr[]?' "$TARGETS")"
            if command -v python3 >/dev/null && [[ -n "$cidrs" ]]; then
                if python3 -c '
import ipaddress, sys
ip = sys.argv[1].split("/")[0]
try:
    addr = ipaddress.ip_address(ip)
except ValueError:
    sys.exit(1)
for cidr in sys.argv[2].splitlines():
    cidr = cidr.strip()
    if not cidr: continue
    try:
        if addr in ipaddress.ip_network(cidr, strict=False):
            sys.exit(0)
    except ValueError: continue
sys.exit(1)
' "$host" "$cidrs"; then echo "$exploit"; return 0; fi
            fi
        fi
    done
    return 1
}

# Default policy when running a local audit with no --target: implicit self.
EXPLOIT_POLICY="allowed"
if [[ -n "$target" ]]; then
    EXPLOIT_POLICY="$(classify_target "$target")" \
        || { echo "REFUSED: '$target' is not authorized in $TARGETS" >&2; exit 3; }
    log "target '$target' authorized — exploitation=$EXPLOIT_POLICY"
else
    log "local-host audit (no target) — exploitation=allowed (self)"
fi

# ─── prepare run dir ─────────────────────────────────────────────────────────
ts="${out_ts:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN="$LOOT_ROOT/$ts"
mkdir -p "$RUN"
manifest="$RUN/manifest.json"
jq -n --arg ts "$ts" --arg p "$preset" --arg t "$target" --arg b "$budget" \
   --arg fs "$FSROOT" \
   '{schema:"scan-run v1",timestamp:$ts,preset:$p,target:$t,budget_s:($b|tonumber),fsroot:$fs,jobs:[]}' \
   > "$manifest"

deadline=$(( $(date +%s) + budget ))
sanitize() { printf '%s' "$1" | tr -c '[:alnum:].-' '_'; }
target_dir="$(sanitize "${target:-_self}")"

# ─── iterate preset → categories → tools ─────────────────────────────────────
for cat in $(jq -r --arg p "$preset" '.presets[$p][]' "$SCANS"); do
    domain="$(jq -r --arg c "$cat" '.categories[$c].domain // empty' "$SCANS")"
    [[ -n "$domain" ]] || { log "skipping unknown category: $cat" >&2; continue; }

    for tool in $(jq -r --arg c "$cat" '.categories[$c].tools[]?' "$SCANS"); do
        now=$(date +%s)
        if (( now >= deadline )); then
            log "BUDGET EXCEEDED — stopping" >&2
            break 2
        fi
        cmd="$(       jq -r --arg t "$tool" '.tools[$t].cmd'                                  "$SCANS")"
        sudo_flag="$( jq -r --arg t "$tool" '.tools[$t].sudo // false'                        "$SCANS")"
        timeout_s="$( jq -r --arg t "$tool" '.tools[$t].timeout_s // (.defaults.timeout_s)'   "$SCANS")"
        ignore_err="$(jq -r --arg t "$tool" '.tools[$t].ignore_errors // (.defaults.ignore_errors)' "$SCANS")"
        stdout_to="$( jq -r --arg t "$tool" '.tools[$t].stdout_to // ""'                      "$SCANS")"
        tool_class="$(jq -r --arg t "$tool" '.tools[$t].category // "recon"'                  "$SCANS")"

        # Exploit-gate: skip exploit tools if scope is recon-only.
        if [[ "$tool_class" == "exploit" && "$EXPLOIT_POLICY" != "allowed" ]]; then
            log "[$domain/$cat] $tool — REFUSED (category=exploit, target policy=$EXPLOIT_POLICY)"
            job="$(jq -n --arg tool "$tool" --arg cat "$cat" --arg dom "$domain" \
                         --arg out "" --argjson rc 0 --argjson dur 0 \
                         --arg note "skipped: exploitation not allowed for this target" \
                         '{tool:$tool,category:$cat,domain:$dom,out_dir:$out,exit_code:$rc,duration_s:$dur,ignored:false,skipped:true,skip_reason:$note}')"
            jq --argjson j "$job" '.jobs += [$j]' "$manifest" > "$manifest.tmp" && mv "$manifest.tmp" "$manifest"
            continue
        fi

        if [[ "$domain" == "network" ]]; then
            outdir="$RUN/network/$target_dir/$cat/$tool"
        else
            outdir="$RUN/local/$cat/$tool"
        fi
        mkdir -p "$outdir"

        # Resolve %placeholders%
        out_primary="$outdir/${stdout_to:-${tool}.out}"
        outbase="$outdir/$tool"

        mapfile -t args < <(jq -r --arg t "$tool" '.tools[$t].args[]?' "$SCANS" | \
            sed -e "s|%TARGET%|${target}|g" \
                -e "s|%OUTDIR%|${outdir}|g" \
                -e "s|%OUT%|${out_primary}|g" \
                -e "s|%OUTBASE%|${outbase}|g" \
                -e "s|%FSROOT%|${FSROOT}|g")

        runner=()
        if [[ "$sudo_flag" == "true" ]] && [[ "$(id -u)" != "0" ]]; then
            runner=(sudo -n)
        fi
        runner+=(timeout --kill-after=10 "$timeout_s" "$cmd")

        log "[$domain/$cat] $tool ..."
        start=$(date +%s); rc=0
        if [[ -n "$stdout_to" ]]; then
            "${runner[@]}" "${args[@]}" > "$outdir/$stdout_to" 2> "$outdir/$tool.stderr" || rc=$?
        else
            "${runner[@]}" "${args[@]}" > "$outdir/$tool.stdout" 2> "$outdir/$tool.stderr" || rc=$?
        fi
        dur=$(( $(date +%s) - start ))

        # Append to manifest (read-modify-write because jq has no in-place)
        job="$(jq -n --arg tool "$tool" --arg cat "$cat" --arg dom "$domain" \
                     --arg out "$outdir" --argjson rc "$rc" --argjson dur "$dur" \
                     --arg ig "$ignore_err" \
                     '{tool:$tool,category:$cat,domain:$dom,out_dir:$out,exit_code:$rc,duration_s:$dur,ignored:($ig=="true" and $rc!=0)}')"
        jq --argjson j "$job" '.jobs += [$j]' "$manifest" > "$manifest.tmp" && mv "$manifest.tmp" "$manifest"

        if (( rc != 0 )) && [[ "$ignore_err" != "true" ]]; then
            log "WARN: $tool exited $rc (continuing)"
        fi
    done
done

# ─── render report ───────────────────────────────────────────────────────────
if command -v reporter.sh >/dev/null 2>&1; then
    reporter.sh "$manifest" || true
fi

# ─── safety analyzer (post-process for safety/red-team presets) ─────────────
case "$preset" in
    safety-report|red-team|tier1-quick|tier2-junior|tier3-senior|tier4-expert|fired-self)
        command -v safety-analyzer.sh >/dev/null 2>&1 && safety-analyzer.sh "$manifest" || true
        ;;
esac

log "DONE — loot at $RUN"
