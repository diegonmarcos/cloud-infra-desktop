#!/usr/bin/env bash
# switch-progress.sh — rich KDE progress dialog for `build.sh switch`.
#
# Keeps the 4-stage model but drives a kdialog --progressbar with REAL data
# parsed live from the shared LOG_FILE: overall %, current stage + per-stage
# fill, layers done/total, elapsed, layers/min rate, ETA, and downloaded size.
# Exits (and closes the dialog) when the watched PID dies.
#
# args: $1=LOG_FILE  $2=IMAGE  $3=watch_pid
#   total layers + total bytes are read from the image manifest (falls back to
#   120 / 0 if docker/manifest is unavailable, so the dialog still runs).
set -u
LOG="${1:?log}"; IMG="${2:-}"; WATCH="${3:-$PPID}"
QDBUS="$(command -v qdbus6 || command -v qdbus || true)"
command -v kdialog >/dev/null 2>&1 || exit 0
[ -n "$QDBUS" ] || exit 0

TOTAL_L=120; TOTAL_B=0
if [ -n "$IMG" ] && command -v docker >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    _mf="$(timeout 8 docker manifest inspect "$IMG" 2>/dev/null)" || _mf=""
    if [ -n "$_mf" ]; then
        _l=$(printf '%s' "$_mf" | jq -r '(.layers // .manifests[0].layers // []) | length' 2>/dev/null)
        _b=$(printf '%s' "$_mf" | jq -r '[(.layers // .manifests[0].layers // [])[].size] | add // 0' 2>/dev/null)
        [ -n "$_l" ] && [ "$_l" -gt 0 ] 2>/dev/null && TOTAL_L=$_l
        [ -n "$_b" ] && [ "$_b" -gt 0 ] 2>/dev/null && TOTAL_B=$_b
    fi
fi

svc="$(kdialog --title 'NixOS switch — live progress' --progressbar 'Starting…' 100 2>/dev/null)" || exit 0
name="${svc%% *}"; path="${svc##* }"
[ -n "$name" ] || exit 0

start=$(date +%s)
gb()  { awk -v b="${1:-0}" 'BEGIN{ printf "%.2f", b/1073741824 }'; }
clk() { local s=${1:-0}; printf "%02d:%02d" $(( s/60 )) $(( s%60 )); }

while kill -0 "$WATCH" 2>/dev/null; do
    now=$(date +%s); el=$(( now - start ))
    done_l=$(command grep -cE ': (Pull complete|Already exists)$' "$LOG" 2>/dev/null); done_l=${done_l:-0}
    [ "$done_l" -gt "$TOTAL_L" ] && done_l=$TOTAL_L
    cur=$(command grep -aE ': (Downloading|Extracting|Verifying Checksum|Waiting|Retrying)' "$LOG" 2>/dev/null | tail -1 | sed 's/^\[[0-9:]*\] //' | cut -c1-58)

    # ── stage detection → base%/span% + per-stage fraction ──
    if command grep -qa 'SAFE TO REBOOT' "$LOG" 2>/dev/null; then
        stage=4; sname="ACTIVATE + bootloader"; base=100; span=0; frac=1
    elif command grep -qa 'activating the configuration' "$LOG" 2>/dev/null; then
        stage=4; sname="ACTIVATE system"; base=90; span=10; frac=0.5
    elif command grep -qaE 'Importing closure|materialised via layered|already present locally|Phase 2: activate' "$LOG" 2>/dev/null; then
        stage=3; sname="MATERIALIZE store"; base=72; span=18; frac=0.5
    elif [ "$done_l" -gt 0 ] || command grep -qa 'Pulling fs layer' "$LOG" 2>/dev/null; then
        stage=2; sname="PULL layers"; base=6; span=66
        frac=$(awk -v d="$done_l" -v t="$TOTAL_L" 'BEGIN{printf "%.4f", (t>0? d/t : 0)}')
    else
        stage=1; sname="INIT / manifest refresh"; base=0; span=6; frac=0.4
    fi
    overall=$(awk -v b="$base" -v s="$span" -v f="$frac" 'BEGIN{v=b+s*f; printf "%d", (v>100?100:v)}')

    # ── rate + ETA (meaningful during the PULL stage) ──
    rate="—"; eta="—"
    if [ "$stage" -eq 2 ] && [ "$done_l" -gt 0 ] && [ "$el" -gt 0 ]; then
        rate=$(awk -v d="$done_l" -v e="$el" 'BEGIN{printf "%.1f", d/(e/60)}')
        eta="~$(clk "$(awk -v r="$((TOTAL_L-done_l))" -v d="$done_l" -v e="$el" 'BEGIN{printf "%d", (d>0? r*(e/d):0)}')")"
    fi
    dl=$(awk -v f="$frac" -v t="$TOTAL_B" 'BEGIN{printf "%d", f*t}')

    label=$(printf 'Overall %d%%   ·   Stage %d/4: %s\n────────────────────────────\nLayers    %d / %d\nDownload  ~%s / %s GB\nElapsed   %s   rate %s/min   ETA %s\nnow: %s' \
        "$overall" "$stage" "$sname" "$done_l" "$TOTAL_L" "$(gb "$dl")" "$(gb "$TOTAL_B")" "$(clk "$el")" "$rate" "$eta" "${cur:-starting…}")

    "$QDBUS" "$name" "$path" setLabelText "$label" 2>/dev/null || break
    "$QDBUS" "$name" "$path" setValue "$overall" 2>/dev/null || true
    sleep 2
done

"$QDBUS" "$name" "$path" setValue 100 2>/dev/null || true
"$QDBUS" "$name" "$path" setLabelText "Switch finished." 2>/dev/null || true
sleep 2
"$QDBUS" "$name" "$path" close 2>/dev/null || true
