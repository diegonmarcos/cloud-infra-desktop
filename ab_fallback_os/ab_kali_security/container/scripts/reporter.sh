#!/usr/bin/env bash
# Render manifest.json → report.md alongside it.
set -euo pipefail
[[ "${VERBOSE:-0}" == "1" ]] && set -x
if [[ "${QUIET:-0}" == "1" ]]; then
    log() { :; }
else
    log() { printf '\033[36m[%s reporter]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fi
manifest="${1:?need path to manifest.json}"
[[ -r "$manifest" ]] || { echo "no such manifest: $manifest" >&2; exit 1; }
report="${manifest%/*}/report.md"

ts="$(jq -r '.timestamp' "$manifest")"
preset="$(jq -r '.preset'  "$manifest")"
target="$(jq -r '.target // "(local)"' "$manifest")"
budget="$(jq -r '.budget_s' "$manifest")"
fsroot="$(jq -r '.fsroot' "$manifest")"

total="$(jq '.jobs|length'                                 "$manifest")"
ok="$(   jq '[.jobs[] | select(.exit_code==0)]    | length' "$manifest")"
warn="$( jq '[.jobs[] | select(.ignored==true)]   | length' "$manifest")"
fail="$( jq '[.jobs[] | select(.exit_code!=0 and .ignored==false)] | length' "$manifest")"
total_dur="$(jq '[.jobs[].duration_s] | add // 0' "$manifest")"

{
    printf "# Scan Report — %s\n\n" "$ts"
    printf "* Preset:    \`%s\`\n"        "$preset"
    printf "* Target:    \`%s\`\n"        "$target"
    printf "* Budget:    %ss\n"           "$budget"
    printf "* FSROOT:    \`%s\`\n"        "$fsroot"
    printf "* Wallclock: %ss\n\n"         "$total_dur"
    printf "## Summary\n\n"
    printf "| OK | Ignored | Failed | Total |\n|---|---|---|---|\n"
    printf "| %s | %s | %s | %s |\n\n" "$ok" "$warn" "$fail" "$total"

    printf "## Jobs\n\n"
    printf "| Domain | Category | Tool | Exit | Duration | Output |\n"
    printf "|---|---|---|---|---|---|\n"
    jq -r '.jobs[] | "| \(.domain) | \(.category) | \(.tool) | \(.exit_code)\(if .ignored then " ⚠️" else "" end) | \(.duration_s)s | \(.out_dir) |"' "$manifest"

    if (( fail > 0 )); then
        printf "\n## Failures\n\n"
        jq -r '.jobs[] | select(.exit_code!=0 and .ignored==false) | "* **\(.tool)** (\(.category)) → exit \(.exit_code) — see `\(.out_dir)/\(.tool).stderr`"' "$manifest"
    fi
} > "$report"

log "wrote $report"
