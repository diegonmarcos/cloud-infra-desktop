#!/usr/bin/env bash
# ============================================================================
# mem-reclaim — data-driven memory panic button
# ============================================================================
# Kills EVERY process owned by this user whose /proc/<pid>/cmdline does NOT match
# the essentials allowlist (data-driven, ~/.config/mem-reclaim/essentials.json),
# EXCEPT the active login session (the terminal + Claude + its MCP children are
# spared via shared session id) and mem-reclaim itself. Writes the killed set to
# $XDG_RUNTIME_DIR/mem-reclaim-killed.<ts>.json (symlinked mem-reclaim-killed.json)
# so `mem-reclaim restore` can best-effort relaunch them.
#
# Matching is on the FULL cmdline, not comm — nix-wrapped binaries report
# truncated ".name-wrapped" comm names that an allowlist can't reliably match.
#
# NO sudo, user processes only. Usage:
#   mem-reclaim            # kill non-essentials now
#   mem-reclaim --dry-run  # preview what would be killed (no kill)
#   mem-reclaim restore    # relaunch what the last run killed (best effort)
# ============================================================================
set -u

# Config: prefer the deployed copy, fall back to the source file beside this script
CFG="${MEM_RECLAIM_CFG:-$HOME/.config/mem-reclaim/essentials.json}"
[ -f "$CFG" ] || CFG="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/mem-reclaim-essentials.json"
[ -f "$CFG" ] || { echo "mem-reclaim: essentials.json not found ($CFG)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "mem-reclaim: jq required" >&2; exit 1; }

ESS="$(jq -r '.essential.cmdline_regex' "$CFG")"
TWAIT="$(jq -r '.signals.term_wait_s // 6' "$CFG")"
MYUID="$(id -u)"
MYSID="$(ps -o sess= -p $$ 2>/dev/null | tr -d ' ')"
RUNDIR="${XDG_RUNTIME_DIR:-/run/user/$MYUID}"
LATEST="$RUNDIR/mem-reclaim-killed.json"

do_reclaim() {
    dry="$1"
    ts="$(date +%Y%m%d-%H%M%S)"
    out="$RUNDIR/mem-reclaim-killed.$ts.json"
    lines="$(mktemp)"
    # Candidate user procs, biggest RSS first. Pipe → while runs in a subshell,
    # so we accumulate into a FILE (not a var) to survive the subshell.
    ps -u "$MYUID" -o pid=,sess=,rss= --sort=-rss 2>/dev/null | while read -r pid sess rss; do
        [ "$pid" = "$$" ] && continue                       # never ourselves
        [ "$sess" = "$MYSID" ] && continue                  # spare the active session (terminal + Claude tree)
        cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
        [ -n "$cmd" ] || continue                           # kernel thread / already gone
        printf '%s' "$cmd" | grep -Eq "$ESS" && continue    # essential → keep
        cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "$HOME")"
        jq -n --argjson pid "$pid" --argjson rss "${rss:-0}" \
              --arg comm "$(cat "/proc/$pid/comm" 2>/dev/null)" --arg cmd "$cmd" --arg cwd "$cwd" \
              '{pid:$pid,rss_kb:$rss,comm:$comm,cmdline:$cmd,cwd:$cwd}' >> "$lines"
        [ "$dry" = "0" ] && kill -TERM "$pid" 2>/dev/null || true
    done
    jq -s --arg ts "$ts" '{killed_at:$ts,count:length,freed_kb:(map(.rss_kb)|add // 0),procs:.}' "$lines" > "$out"
    rm -f "$lines"
    n="$(jq -r '.count' "$out")"; freed="$(jq -r '.freed_kb' "$out")"
    if [ "$dry" = "1" ]; then
        echo "[mem-reclaim] DRY-RUN — would kill $n proc(s), ~$((freed/1024))MB:"
        jq -r '.procs[] | "  \(.rss_kb/1024|floor)MB  pid=\(.pid)  \(.comm)"' "$out"
        echo "[mem-reclaim] (preview written to $out — nothing was killed)"
    else
        ln -sf "$out" "$LATEST"
        sleep "$TWAIT"
        jq -r '.procs[].pid' "$out" | while read -r p; do
            kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
        done
        echo "[mem-reclaim] killed $n proc(s), freed ~$((freed/1024))MB"
        echo "[mem-reclaim] record: $out  (run 'mem-reclaim restore' to relaunch)"
    fi
}

do_restore() {
    [ -e "$LATEST" ] || { echo "mem-reclaim: no killed record at $LATEST"; exit 1; }
    jq -r '.procs[] | [.cwd, .cmdline] | @tsv' "$LATEST" | while IFS="$(printf '\t')" read -r cwd cmd; do
        [ -n "$cmd" ] || continue
        ( cd "$cwd" 2>/dev/null || cd "$HOME"; setsid sh -c "$cmd" >/dev/null 2>&1 & )
        echo "[mem-restore] relaunched (cwd=$cwd): $cmd"
    done
}

case "${1:-kill}" in
    kill|"")           do_reclaim 0 ;;
    -n|--dry-run|dry)  do_reclaim 1 ;;
    restore)           do_restore ;;
    *) echo "usage: mem-reclaim [kill|--dry-run|restore]"; exit 1 ;;
esac
