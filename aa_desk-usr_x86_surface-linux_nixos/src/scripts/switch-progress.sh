#!/usr/bin/env bash
# switch-progress.sh — LIVE DASHBOARD for `build.sh switch`.
#
# Spawns a konsole window running a full-redraw TUI (2s tick) with:
#   · two progress bars — OVERALL (all 4 stages) + CURRENT STEP
#   · stage timeline with per-stage elapsed times
#   · layers done/total · cached · remaining · in-flight layer + state
#   · downloaded GB / total GB · live network RX MB/s · session RX total
#   · layers/min rate · step ETA · overall ETA
#   · workload.slice cgroup mem · system RAM/swap · loadavg · /nix + p5 disk
#   · registry retry/waiting counts + flaky warning
#   · target store path vs currently-active generation
#   · last 5 raw log lines
# Fires notify-send KDE alerts on every stage transition + final result.
#
# 2026-07-21: replaces the yad --multi-progress dialog — its --enable-log
# panel rendered EMPTY in multi-progress mode (bars worked, telemetry never
# showed). A konsole TUI always renders and holds no such surprises.
#
# args: $1=LOG_FILE  $2=IMAGE  $3=watch_pid          (spawn mode: opens konsole)
#       --tui LOG IMAGE WATCH_PID                    (internal: the TUI itself)
set -u

# ── spawn mode: KDE popup window (yad --text-info --tail) fed by the TUI ──
# 2026-07-21: Diego wants a real KDE popup, NOT a terminal. yad --text-info
# streams unlimited appended text into a GUI window; the --tui renderer below
# is reused with DASH_PLAIN=1 (no clear/ANSI, appends snapshot blocks).
if [ "${1:-}" != "--tui" ]; then
    LOG="${1:?log}"; IMG="${2:-}"; WATCH="${3:-$PPID}"
    # 1) terminal TUI dashboard in a konsole window
    if command -v konsole >/dev/null 2>&1; then
        setsid konsole --title "NixOS switch — live dashboard (TUI)" --hold \
            -e bash "$0" --tui "$LOG" "$IMG" "$WATCH" </dev/null >/dev/null 2>&1 &
    fi
    # 2) KDE popup GUI of the same data
    if command -v yad >/dev/null 2>&1; then
        setsid bash -c '
            DASH_PLAIN=1 bash "$1" --tui "$2" "$3" "$4" | yad --text-info --tail \
                --title "NixOS switch — LIVE DASHBOARD" \
                --width=780 --height=680 --fontname="monospace 9" \
                --button="📜 Open byte-log:setsid konsole --hold -e tail -n +1 -F $2" \
                --button="Close:1"
        ' _ "$0" "$LOG" "$IMG" "$WATCH" </dev/null >/dev/null 2>&1 &
    fi
    exit 0
fi

shift
LOG="${1:?log}"; IMG="${2:-}"; WATCH="${3:-$PPID}"

# ── denominators + digest from the image manifest (fallback 120 / 0) ──
TOTAL_L=120; TOTAL_B=0; DIGEST="—"
if [ -n "$IMG" ] && command -v docker >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    _mf="$(timeout 8 docker manifest inspect "$IMG" 2>/dev/null)" || _mf=""
    if [ -n "$_mf" ]; then
        _l=$(printf '%s' "$_mf" | jq -r '(.layers // .manifests[0].layers // []) | length' 2>/dev/null)
        _b=$(printf '%s' "$_mf" | jq -r '[(.layers // .manifests[0].layers // [])[].size] | add // 0' 2>/dev/null)
        _d=$(printf '%s' "$_mf" | jq -r '.config.digest // .manifests[0].digest // "—"' 2>/dev/null)
        [ -n "$_l" ] && [ "$_l" -gt 0 ] 2>/dev/null && TOTAL_L=$_l
        [ -n "$_b" ] && [ "$_b" -gt 0 ] 2>/dev/null && TOTAL_B=$_b
        [ -n "$_d" ] && { DIGEST="${_d#sha256:}"; DIGEST="${DIGEST:0:12}"; }
    fi
fi

# pull-carrying network iface
IFACE=""
for _p in /sys/class/net/*; do
    _n=$(basename "$_p")
    case "$_n" in lo|docker*|veth*|br-*|virbr*|wg*) continue ;; esac
    [ "$(cat "$_p/operstate" 2>/dev/null)" = "up" ] && { IFACE="$_n"; break; }
done

B="\033[1m"; DIM="\033[2m"; R="\033[0m"
GRN="\033[32m"; YLW="\033[33m"; CYN="\033[36m"; RED="\033[31m"
# DASH_PLAIN=1 → plain text feed for the yad GUI popup (no ANSI, no clear)
if [ -n "${DASH_PLAIN:-}" ]; then
    B=""; DIM=""; R=""; GRN=""; YLW=""; CYN=""; RED=""
    clear() { printf '\n'; }
fi
gb()  { awk -v b="${1:-0}" 'BEGIN{ printf "%.2f", b/1073741824 }'; }
mb()  { awk -v b="${1:-0}" 'BEGIN{ printf "%.0f", b/1048576 }'; }
clk() { local s=${1:-0}; printf "%02d:%02d" $(( s/60 )) $(( s%60 )); }
rx()  { cat "/sys/class/net/${IFACE:-none}/statistics/rx_bytes" 2>/dev/null || echo 0; }
cnt() { local c; c=$(command grep -acE "$1" "$LOG" 2>/dev/null); echo "${c:-0}"; }
bar() { # $1=pct $2=width → ██████░░░░
    local p=${1:-0} w=${2:-40} f
    f=$(( p * w / 100 )); [ "$f" -gt "$w" ] && f=$w
    printf '%*s' "$f" '' | tr ' ' '█'; printf '%*s' $(( w - f )) '' | tr ' ' '░'
}
notify() { command -v notify-send >/dev/null 2>&1 && notify-send -u "${3:-normal}" -i nix-snowflake-white "$1" "$2" 2>/dev/null; }

start=$(date +%s)
prev_rx=$(rx); prev_t=$start
last_stage=0
declare -A stage_t0 stage_el
df_line="—"; tick=0
active_gen="$(readlink /nix/var/nix/profiles/system 2>/dev/null || echo '?')"
toplevel=""

while :; do
    alive=1; kill -0 "$WATCH" 2>/dev/null || alive=0
    now=$(date +%s); el=$(( now - start ))
    done_l=$(command grep -cE ': (Pull complete|Already exists)$' "$LOG" 2>/dev/null); done_l=${done_l:-0}
    [ "$done_l" -gt "$TOTAL_L" ] && done_l=$TOTAL_L
    rem=$(( TOTAL_L - done_l ))
    pc=$(cnt ': Pull complete$'); ae=$(cnt ': Already exists$')
    retries=$(cnt 'Retrying'); waiting=$(cnt 'Waiting')
    infl=$(command grep -aE ': (Downloading|Extracting|Verifying Checksum|Waiting|Retrying)' "$LOG" 2>/dev/null | tail -1 | sed 's/^\[[0-9:]*\] //' | cut -c1-66)

    # ── stage machine ──
    if command grep -qa 'SAFE TO REBOOT' "$LOG" 2>/dev/null; then
        stage=5; sname="DONE"; base=100; span=0; step=1
    elif command grep -qa 'activating the configuration' "$LOG" 2>/dev/null; then
        stage=4; sname="ACTIVATE"; base=90; span=10; step=0.6
    elif command grep -qaE 'Importing closure|materialised via layered|already present locally|Phase 2: activate' "$LOG" 2>/dev/null; then
        stage=3; sname="MATERIALIZE"; base=72; span=18; step=0.5
    elif [ "$done_l" -gt 0 ] || command grep -qa 'Pulling fs layer' "$LOG" 2>/dev/null; then
        stage=2; sname="PULL"; base=6; span=66
        step=$(awk -v d="$done_l" -v t="$TOTAL_L" 'BEGIN{printf "%.4f", (t>0? d/t : 0)}')
    else
        stage=1; sname="INIT"; base=0; span=6; step=0.4
    fi
    # stage-transition bookkeeping + KDE alert
    if [ "$stage" -ne "$last_stage" ]; then
        stage_t0[$stage]=$now
        [ "$last_stage" -ge 1 ] && stage_el[$last_stage]=$(( now - ${stage_t0[$last_stage]:-$now} ))
        case "$stage" in
            2) notify "NixOS switch — PULL started"       "pulling $TOTAL_L layers ($(gb "$TOTAL_B") GB) from GHCR" ;;
            3) notify "NixOS switch — PULL done"          "materializing closure into /nix/store" ;;
            4) notify "NixOS switch — ACTIVATING"         "switch-to-configuration running" ;;
            5) notify "NixOS switch — ✅ DONE"            "SAFE TO REBOOT — generation activated" ;;
        esac
        last_stage=$stage
    fi
    overall=$(awk -v b="$base" -v s="$span" -v f="$step" 'BEGIN{v=b+s*f; printf "%d", (v>100?100:v)}')
    steppct=$(awk -v f="$step" 'BEGIN{v=f*100; printf "%d", (v>100?100:v)}')

    rate="—"; seta="—"; oeta="—"
    if [ "$stage" -eq 2 ] && [ "$done_l" -gt 0 ] && [ "$el" -gt 0 ]; then
        rate=$(awk -v d="$done_l" -v e="$el" 'BEGIN{printf "%.1f", d/(e/60)}')
        _s=$(awk -v r="$rem" -v d="$done_l" -v e="$el" 'BEGIN{printf "%d", (d>0? r*(e/d):0)}')
        seta="~$(clk "$_s")"; oeta="~$(clk $(( _s + 240 )))"   # +~4min for materialize+activate
    fi
    dl=$(awk -v f="$step" -v t="$TOTAL_B" 'BEGIN{printf "%d", f*t}')

    cur_rx=$(rx); dt=$(( now - prev_t )); [ "$dt" -lt 1 ] && dt=1
    rxr=$(awk -v a="$prev_rx" -v b="$cur_rx" -v d="$dt" 'BEGIN{r=(b-a)/d/1048576; printf "%.2f", (r<0?0:r)}')
    prev_rx=$cur_rx; prev_t=$now

    iso=$(mb "$(cat /sys/fs/cgroup/workload.slice/memory.current 2>/dev/null || echo 0)")
    read -r ram_used ram_avail < <(free -m | awk '/^Mem:/{print $3, $7}')
    swap_used=$(free -m | awk '/^Swap:/{print $3}')
    loadavg=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
    nix_free=$(df -h /nix 2>/dev/null | awk 'NR==2{print $4}')
    p5_free=$(df -h /mnt/shared-lib 2>/dev/null | awk 'NR==2{print $4}')
    [ $(( tick % 10 )) -eq 0 ] && df_line=$(timeout 4 docker system df 2>/dev/null | awk '/^Images/{print $4" ("$5" reclaimable)"}')
    tick=$(( tick + 1 ))
    [ -z "$toplevel" ] && toplevel=$(cat "$(dirname "$LOG")/../dist-ci/toplevel.name" 2>/dev/null | head -c 70)

    flaky="ok"; [ "$retries" -gt 8 ] 2>/dev/null && flaky="${RED}⚠ GHCR FLAKY${R}"

    # stage timeline glyphs
    tl=""
    for s in 1 2 3 4; do
        n=$( [ $s -eq 1 ] && echo INIT || { [ $s -eq 2 ] && echo PULL || { [ $s -eq 3 ] && echo MATERIALIZE || echo ACTIVATE; }; } )
        if [ "$stage" -gt "$s" ] || [ "$stage" -eq 5 ]; then
            tl+="${GRN}✔ $n${R} ${DIM}$(clk "${stage_el[$s]:-0}")${R}   "
        elif [ "$stage" -eq "$s" ]; then
            tl+="${YLW}▶ $n${R} $(clk $(( now - ${stage_t0[$s]:-$now} )))   "
        else
            tl+="${DIM}· $n${R}   "
        fi
    done

    clear
    printf "${B}${CYN}╔══════════════════ NixOS SWITCH — LIVE DASHBOARD ══════════════════╗${R}\n"
    printf "  image   %s\n" "${IMG##*/}  ${DIM}digest ${DIGEST}${R}"
    printf "  target  %s\n" "${toplevel:-<resolving>}"
    printf "  active  %s\n" "$active_gen"
    printf "\n"
    printf "  ${B}OVERALL ${R} [%s] ${B}%3d%%${R}   elapsed %s   ETA %s\n" "$(bar "$overall" 44)" "$overall" "$(clk "$el")" "$oeta"
    printf "  ${B}STEP %d/4${R} [%s] ${B}%3d%%${R}   %s   ETA %s\n" "$(( stage>4?4:stage ))" "$(bar "$steppct" 44)" "$steppct" "$sname" "$seta"
    printf "\n  %b\n\n" "$tl"
    printf "  ${B}Layers${R}     %d / %d    pulled %d · cached %d · ${B}remaining %d${R}\n" "$done_l" "$TOTAL_L" "$pc" "$ae" "$rem"
    printf "  ${B}In-flight${R}  %s\n" "${infl:-—}"
    printf "  ${B}Download${R}   ~%s / %s GB    rate %s layers/min\n" "$(gb "$dl")" "$(gb "$TOTAL_B")" "$rate"
    printf "  ${B}Network${R}    ↓ %s MB/s now   (RX total %s GB on %s)\n" "$rxr" "$(gb "$cur_rx")" "${IFACE:-?}"
    printf "  ${B}Registry${R}   retries %s · waiting %s   %b\n" "$retries" "$waiting" "$flaky"
    printf "\n"
    printf "  ${B}Isolation${R}  workload.slice %s MB used (cap 3G mem · 6G swap)\n" "$iso"
    printf "  ${B}System${R}     RAM %sM used · %sM avail   swap %sM   load %s\n" "${ram_used:-?}" "${ram_avail:-?}" "${swap_used:-?}" "${loadavg:-?}"
    printf "  ${B}Disk${R}       /nix free %s   ·   p5 free %s   ·   docker img %s\n" "${nix_free:-?}" "${p5_free:-?}" "${df_line:-—}"
    printf "\n  ${B}${DIM}── last log lines ──────────────────────────────────────────────${R}\n"
    command grep -av '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -5 | cut -c1-78 | sed 's/^/  /'
    printf "  ${DIM}log: %s${R}\n" "$LOG"

    if [ "$stage" -eq 5 ]; then
        printf "\n  ${GRN}${B}✅ SWITCH COMPLETE — SAFE TO REBOOT${R}\n"; break
    fi
    if [ "$alive" -eq 0 ]; then
        if command grep -qaE 'unexpected EOF|import failed|error' "$LOG" 2>/dev/null; then
            printf "\n  ${RED}${B}❌ SWITCH PROCESS DIED — see log above${R}\n"
            notify "NixOS switch — ❌ FAILED" "process died before completion — check dashboard" critical
        else
            printf "\n  ${YLW}${B}⚠ switch process ended (no SAFE TO REBOOT marker) — verify manually${R}\n"
            notify "NixOS switch — ended" "no completion marker; verify generation" critical
        fi
        break
    fi
    sleep 2
done
