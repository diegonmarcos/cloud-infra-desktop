#!/usr/bin/env bash

# Read JSON input from stdin — single jq call extracts everything
input=$(cat)
eval "$(echo "$input" | jq -r '
    @sh "cwd=\(.workspace.current_dir)",
    @sh "model_id=\(.model.id)",
    @sh "transcript_path=\(.transcript_path)",
    @sh "exceeds_200k=\(.exceeds_200k_tokens // false)",
    @sh "ctx_input=\(.context_window.total_input_tokens // 0)",
    @sh "ctx_output=\(.context_window.total_output_tokens // 0)",
    @sh "ctx_window=\(.context_window.context_window_size // 200000)",
    @sh "ctx_used_pct=\(.context_window.used_percentage // -1)",
    @sh "cu_new=\(.context_window.current_usage.input_tokens // 0)",
    @sh "cu_cwrite=\(.context_window.current_usage.cache_creation_input_tokens // 0)",
    @sh "cu_cread=\(.context_window.current_usage.cache_read_input_tokens // 0)",
    @sh "cu_out=\(.context_window.current_usage.output_tokens // 0)",
    @sh "session_cost=\(.cost.total_cost_usd // 0)",
    @sh "session_id=\(.session_id // empty)",
    @sh "effort_level=\(.effort.level // empty)",
    @sh "session_name=\(.session_name // empty)",
    @sh "rl_5h=\(.rate_limits.five_hour.used_percentage // empty)",
    @sh "rl_7d=\(.rate_limits.seven_day.used_percentage // empty)"
')"

# Fallback session ID from transcript path
[ -z "$session_id" ] && session_id=$(basename "$(dirname "$transcript_path")" 2>/dev/null)
session_short="${session_id:0:8}"

# Custom session name capped to 13 display chars (ellipsis when longer)
session_name_disp="$session_name"
[ "${#session_name_disp}" -gt 13 ] && session_name_disp="${session_name:0:12}…"

# Model name (strip claude- prefix and date suffix)
model_name=$(echo "$model_id" | sed -E 's/^claude-//; s/-([0-9]{8})$//')
[ -z "$model_name" ] && model_name="unknown"

# Context window — size is model-dependent (200K, or 1M extended-context).
# current_ctx = total input in the live window (new + cache-write + cache-read).
ctx_window_size=${ctx_window:-200000}
current_ctx=${ctx_input:-0}
# Prefer Claude Code's pre-computed used_percentage; else derive from window size.
if [ -n "$ctx_used_pct" ] && [ "$ctx_used_pct" != "-1" ]; then
    ctx_percent=${ctx_used_pct%.*}
elif [ "$current_ctx" -gt 0 ] && [ "$ctx_window_size" -gt 0 ]; then
    ctx_percent=$((current_ctx * 100 / ctx_window_size))
else
    ctx_percent=0
fi
case "$ctx_percent" in ""|*[!0-9]*) ctx_percent=0;; esac

# Context color
if [ "$exceeds_200k" = "true" ] || [ "$ctx_percent" -ge 95 ]; then
    ctx_color="31"
elif [ "$ctx_percent" -ge 50 ]; then
    ctx_color="33"
else
    ctx_color="32"
fi

# === Context Reset Detection ===
ctx_state_file="/tmp/statusline_ctx_state_$(echo "$transcript_path" | md5sum | cut -c1-8).dat"
ctx_reset_file="/tmp/statusline_ctx_reset_$(echo "$transcript_path" | md5sum | cut -c1-8).dat"

now_epoch=$(date +%s)
# fmt_age: seconds -> compact live string that ticks every refreshInterval.
fmt_age() { local s=${1:-0}; [ "$s" -lt 0 ] && s=0
    if [ "$s" -lt 60 ]; then echo "${s}s"
    elif [ "$s" -lt 3600 ]; then echo "$((s/60))m$((s%60))s"
    else echo "$((s/3600))h$(((s%3600)/60))m"; fi; }
prev_ctx=0; prev_exceeds="false"; prev_epoch=$now_epoch
[ -f "$ctx_state_file" ] && read prev_ctx prev_exceeds prev_epoch < "$ctx_state_file" 2>/dev/null
[ -z "$prev_ctx" ] && prev_ctx=0
[ -z "$prev_exceeds" ] && prev_exceeds="false"
[ -z "$prev_epoch" ] && prev_epoch=$now_epoch

ctx_reset_detected="false"
if [ "$prev_ctx" -gt 50000 ] && [ "$current_ctx" -gt 0 ]; then
    [ "$current_ctx" -lt $((prev_ctx / 2)) ] && ctx_reset_detected="true"
fi
[ "$prev_exceeds" = "true" ] && [ "$exceeds_200k" = "false" ] && ctx_reset_detected="true"

[ "$ctx_reset_detected" = "true" ] && echo "$(date -Iseconds) $prev_ctx $current_ctx" >> "$ctx_reset_file"
# "last cache hit" = last render where the context changed (= last API response).
# Idle re-renders keep the same epoch, so the minutes-since grows while you sit.
if [ "$current_ctx" != "$prev_ctx" ]; then last_epoch=$now_epoch; else last_epoch=$prev_epoch; fi
secs_since=$(( now_epoch - last_epoch ))
echo "$current_ctx $exceeds_200k $last_epoch" > "$ctx_state_file"

last_reset_ts="never"
if [ -f "$ctx_reset_file" ]; then
    last_reset_line=$(tail -1 "$ctx_reset_file" 2>/dev/null)
    [ -n "$last_reset_line" ] && last_reset_ts=$(date -d "$(echo "$last_reset_line" | cut -d' ' -f1)" "+%m-%d %H:%M" 2>/dev/null || echo "?")
fi

# === Prompt/action age timers — time since the last `user` and last
# `assistant` transcript entries. Recomputed live every refreshInterval tick.
# The tac|jq scan is cached against transcript size, so idle refreshes are just
# a stat + subtraction — no rescan until a new turn grows the transcript.
age_cache="/tmp/statusline_age_$(echo "$transcript_path" | md5sum | cut -c1-8).dat"
prompt_age="?"; action_age="?"
if [ -f "$transcript_path" ]; then
    tsize=$(stat -c %s "$transcript_path" 2>/dev/null || echo 0)
    c_size=""; last_user_ts=""; last_asst_ts=""
    [ -f "$age_cache" ] && read -r c_size last_user_ts last_asst_ts < "$age_cache" 2>/dev/null
    if [ "$tsize" != "$c_size" ]; then
        last_user_ts=$(tac "$transcript_path" 2>/dev/null | jq -r 'select(.type=="user") | .timestamp' 2>/dev/null | head -1)
        last_asst_ts=$(tac "$transcript_path" 2>/dev/null | jq -r 'select(.type=="assistant") | .timestamp' 2>/dev/null | head -1)
        echo "$tsize $last_user_ts $last_asst_ts" > "$age_cache"
    fi
    if [ -n "$last_user_ts" ] && [ "$last_user_ts" != "null" ]; then
        u_epoch=$(date -d "$last_user_ts" +%s 2>/dev/null)
        [ -n "$u_epoch" ] && prompt_age=$(fmt_age $(( now_epoch - u_epoch )))
    fi
    if [ -n "$last_asst_ts" ] && [ "$last_asst_ts" != "null" ]; then
        a_epoch=$(date -d "$last_asst_ts" +%s 2>/dev/null)
        [ -n "$a_epoch" ] && action_age=$(fmt_age $(( now_epoch - a_epoch )))
    fi
fi

# Cost color
cost_cents=$(LC_NUMERIC=C awk "BEGIN {printf \"%.0f\", ${session_cost:-0} * 100}")
[ -z "$cost_cents" ] && cost_cents=0
if [ "$cost_cents" -ge 1000 ]; then
    cost_color="31"
elif [ "$cost_cents" -ge 500 ]; then
    cost_color="33"
else
    cost_color="32"
fi

# MCP server count
mcp_configured=0
[ -f "$HOME/.mcp.json" ] && { n=$(jq '.mcpServers // {} | keys | length' "$HOME/.mcp.json" 2>/dev/null); [ -n "$n" ] && mcp_configured=$((mcp_configured + n)); }
[ -f "${cwd}/.mcp.json" ] && { n=$(jq '.mcpServers // {} | keys | length' "${cwd}/.mcp.json" 2>/dev/null); [ -n "$n" ] && mcp_configured=$((mcp_configured + n)); }
[ "$mcp_configured" -gt 0 ] && mcp_color="32" || mcp_color="90"

# Subagent (.md) count — user (~/.claude/agents) + plugin-provided agent defs.
# Mirrors the MCP count above (README.md is the dir's index, not an agent).
agents_configured=$(find "$HOME/.claude/agents" -maxdepth 1 -name '*.md' ! -name 'README.md' 2>/dev/null | wc -l)
n=$(find "$HOME/.claude/plugins/cache" -path '*/agents/*.md' 2>/dev/null | wc -l)
agents_configured=$((agents_configured + n))
[ "$agents_configured" -gt 0 ] && agents_color="32" || agents_color="90"

# Per-MCP online/offline icons (lazy 15-min cache) + plugin status PL[...].
# Both helpers emit literal \033 escapes; the final `printf %b` renders them.
mcp_seg=$(bash "$HOME/.claude/claude-mcp-status.sh" "$cwd" 2>/dev/null)
plugins_seg=$(bash "$HOME/.claude/claude-plugins-status.sh" --format ansi 2>/dev/null)
hooks_seg=$(bash "$HOME/.claude/claude-hooks-status.sh" --format ansi 2>/dev/null)

# user@host (date removed from LINE 1 per 2026-06-25 layout change)
user_host="$(whoami)@$(hostname -s)"

# Format token count (K/M)
fmt_tok() {
    local t=$1
    if [ "$t" -ge 1000000 ]; then echo "$((t / 1000000))M"
    elif [ "$t" -ge 1000 ]; then echo "$((t / 1000))K"
    else echo "$t"; fi
}

# Color by percentage threshold
get_color() {
    local p=$1
    if [ "$p" = "N/A" ]; then echo "90"
    elif [ "$p" -ge 80 ]; then echo "31"
    elif [ "$p" -ge 50 ]; then echo "33"
    else echo "32"; fi
}

# === Git info — repo name + branch for LINE 1 (cheap: ONE `git rev-parse`) ===
# Re-enabled 2026-06-25 for the "repo/folder @ branch" display. The 2026-04-28
# disable was about a 9-fork block — esp. `ls-files --others` walking rust
# target/ (~100k files) ×parallel sessions = ~9% of a core 24/7. This does ONE
# rev-parse (branch + toplevel, no tree walk, no status), cached 10s per cwd →
# negligible. To restore dirty/ahead/behind/stash icons, swap in the
# `git status -b --porcelain=v1` one-forker (see git history).
git_repo=""; git_branch=""
if command -v git >/dev/null 2>&1; then
    git_cache="/tmp/statusline_git_$(printf '%s' "$cwd" | md5sum | cut -c1-8).cache"
    git_cache_age=$(( $(date +%s) - $(stat -c %Y "$git_cache" 2>/dev/null || echo 0) ))
    if [ -f "$git_cache" ] && [ "$git_cache_age" -lt 10 ]; then
        IFS='|' read -r git_repo git_branch < "$git_cache" 2>/dev/null
    else
        # one fork: line 1 = branch (or "HEAD" when detached), line 2 = repo root
        git_info=$(git -C "$cwd" rev-parse --abbrev-ref HEAD --show-toplevel 2>/dev/null)
        if [ -n "$git_info" ]; then
            git_branch=$(printf '%s\n' "$git_info" | sed -n 1p)
            git_repo=$(basename "$(printf '%s\n' "$git_info" | sed -n 2p)")
        fi
        printf '%s|%s\n' "$git_repo" "$git_branch" > "$git_cache"
    fi
fi

# === Async system metrics — all slow commands run in parallel ===
_async="/tmp/statusline_async_$$"
mkdir -p "$_async"

# RAM + Disk (instant)
mem_info=$(free | grep Mem)
mem_total=$(echo "$mem_info" | awk '{print $2}')
mem_used=$(echo "$mem_info" | awk '{print $3}')
mem_percent=$(awk "BEGIN {printf \"%.0f\", ($mem_used/$mem_total)*100}")

if [ -d "/data/data/com.termux.nix" ]; then
    disk_percent=$(df /data | tail -n 1 | awk '{print $5}' | sed 's/%//')
else
    disk_percent=$(df / | tail -n 1 | awk '{print $5}' | sed 's/%//')
fi

# Find ip command once
IP_CMD=""
for p in /sbin/ip /usr/sbin/ip /bin/ip $HOME/.nix-profile/bin/ip /run/current-system/sw/bin/ip; do
    [ -x "$p" ] && IP_CMD="$p" && break
done

# --- Background: CPU (100ms) ---
(
    cpu=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else printf "%.0f", (($2+$4-u1) * 100 / (t-t1))}' <(grep 'cpu ' /proc/stat) <(sleep 0.1; grep 'cpu ' /proc/stat))
    echo "${cpu:-0}" > "$_async/cpu"
) &

# === Expensive probes — STUBBED (mirrors termux statusline) ===
# Reason this is the desktop default: the mesh-status + public-IP curls fired
# on EVERY status render (external network calls per refresh), and VRAM via
# nvidia-smi is wasted on the Surface's Intel iGPU. The private-IP probe forks
# `ip route get` + reads /proc/net/fib_trie every render despite barely
# changing. Static stubs preserve the rendering contract; vars below are read
# by the render block unchanged. To make any of these live, replace the
# matching stub with its probe (restore from git history).
echo "N/A" > "$_async/vram"
# --- Background: WireGuard mesh probe (re-enabled 2026-06-25) ---
# Root-free, NO network: per WG interface, just admin-up state + address via `ip`
# (handshakes need root). The 2026-04 disable was about EXTERNAL public-IP / mesh
# curls firing per render — those stay gone. Interfaces are DATA-DRIVEN from
# `wg show interfaces`, so wg0 + wg-public (and any future wg iface) are covered.
(
    seg=""
    if command -v wg >/dev/null 2>&1; then
        for wif in $(wg show interfaces 2>/dev/null); do
            if ${IP_CMD:-ip} -o link show "$wif" 2>/dev/null | grep -qE "[<,]UP[,>]"; then
                wip=$(${IP_CMD:-ip} -4 -o addr show "$wif" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
                seg="$seg ${wif}:up:${wip:-?}"
            else
                seg="$seg ${wif}:down"
            fi
        done
    fi
    echo "${seg# }" > "$_async/mesh"
) &

# Wait for the only remaining background job (CPU sample, bounded by sleep 0.1)
wait 2>/dev/null

# Read async results
cpu_percent=$(cat "$_async/cpu" 2>/dev/null); [ -z "$cpu_percent" ] && cpu_percent=0
vram_percent=$(cat "$_async/vram" 2>/dev/null); [ -z "$vram_percent" ] && vram_percent="N/A"
mesh_seg=$(cat "$_async/mesh" 2>/dev/null)   # "wg0:up:10.0.0.5 wg-public:up:10.1.0.5"
rm -rf "$_async"

# Colors
mem_color=$(get_color "$mem_percent")
cpu_color=$(get_color "$cpu_percent")
disk_color=$(get_color "$disk_percent")
vram_color=$(get_color "$vram_percent")

# Battery — instant sysfs read (no fork). BAT* = laptop, battery = fallback.
# Low %% is bad, so this is colored inverse of the load metrics above.
bat_percent="N/A"; bat_color="90"
for _b in /sys/class/power_supply/BAT*/capacity /sys/class/power_supply/battery/capacity; do
    [ -r "$_b" ] && { bat_percent=$(cat "$_b" 2>/dev/null); break; }
done
case "$bat_percent" in
    ""|*[!0-9]*) bat_percent="N/A"; bat_color="90" ;;
    *) if [ "$bat_percent" -le 15 ]; then bat_color="31"
       elif [ "$bat_percent" -le 40 ]; then bat_color="33"
       else bat_color="32"; fi ;;
esac

# === BUILD OUTPUT ===
OUT=""

# LINE 1: | model@effort | session@name | MCP | PL | HK | user@OS | folder@branch |
# Date dropped 2026-06-25; every segment is now its own │-delimited cell.
OUT+="\033[37m|\033[0m"
# model @ effort  (effort omitted when the model doesn't support the param)
OUT+=" \033[35m${model_name}\033[0m"
[ -n "$effort_level" ] && OUT+=" \033[90m@\033[0m \033[36m${effort_level}\033[0m"
# session id @ name  (name omitted when no /rename or --name set)
OUT+=" \033[37m|\033[0m"
OUT+=" \033[90m${session_short}\033[0m"
[ -n "$session_name" ] && OUT+=" \033[90m@\033[0m \033[37m${session_name_disp}\033[0m"
# MCP cell (fallback to count if the probe emitted nothing)
OUT+=" \033[37m|\033[0m"
if [ -n "$mcp_seg" ]; then OUT+=" ${mcp_seg}"; else OUT+=" \033[${mcp_color}mMCP:${mcp_configured}\033[0m"; fi
OUT+=" \033[${agents_color}mAgents:${agents_configured}\033[0m"
# PL / HK cells — only when their helper produced output (self-omitting)
[ -n "$plugins_seg" ] && OUT+=" \033[37m|\033[0m ${plugins_seg}"
[ -n "$hooks_seg" ] && OUT+=" \033[37m|\033[0m ${hooks_seg}"
OUT+=" \033[37m|\033[0m\n"

# LINE 2: | user@OS | folder@branch | RAM CPU Disk VRAM | Mesh ●wg0:ip ●wg-public:ip |
# user@host + folder@branch moved here from LINE 1 (2026-06-25).
OUT+="\033[37m|\033[0m"
OUT+=" \033[36m${user_host}\033[0m"
# folder@branch cell (collapse repo/folder when folder == repo root, or no repo)
OUT+=" \033[37m|\033[0m"
folder=$(basename "$cwd")
if [ -n "$git_repo" ] && [ "$git_repo" != "$folder" ]; then
    OUT+=" \033[34m${git_repo}/${folder}\033[0m"
else
    OUT+=" \033[34m${folder}\033[0m"
fi
[ -n "$git_branch" ] && OUT+=" \033[90m@\033[0m \033[33m${git_branch}\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[${mem_color}mRAM:${mem_percent}%\033[0m"
OUT+=" \033[${cpu_color}mCPU:${cpu_percent}%\033[0m"
OUT+=" \033[${disk_color}mDisk:${disk_percent}%\033[0m"
OUT+=" \033[${vram_color}mVRAM:${vram_percent}%\033[0m"
OUT+=" \033[${bat_color}mBattery:${bat_percent}%\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[1;37mMesh\033[0m"
if [ -n "$mesh_seg" ]; then
    for tok in $mesh_seg; do
        wif=${tok%%:*}; rest=${tok#*:}
        if [ "${rest%%:*}" = "up" ]; then
            OUT+=" \033[32m●\033[0m\033[36m${wif}:${rest#up:}\033[0m"
        else
            OUT+=" \033[31m○${wif}\033[0m"
        fi
    done
else
    OUT+=" \033[90m—\033[0m"
fi
OUT+=" \033[37m|\033[0m\n"

# LINE 3 — ONE line, three blocks separated by │ (per spec):
#   <datetime> │ Tok In Cache Out Σ │ $ In Out Cache Σ │ Ctx:used/win(%) Cache:hit% <idle>m
# Tokens = LIVE context window (context_window.current_usage) from stdin (spawn-free).
# $ = THIS turn = tokens/1e6 × per-MTok price from claude-pricing.json (data-driven).
PRICING="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claude-pricing.json"
p_in=15; p_out=75; p_cr=1.50; p_cw=18.75            # fallback (Opus) if JSON/jq absent
if command -v jq >/dev/null 2>&1 && [ -f "$PRICING" ]; then
    read p_in p_out p_cr p_cw < <(jq -r --arg m "$model_id" '
        . as $root
        | (($root.models | to_entries
            | map(select(.key as $k | ($m | startswith($k))))
            | sort_by(.key | length) | last | .value) // $root.default)
        | "\(.input) \(.output) \(.cache_read) \(.cache_write)"' "$PRICING" 2>/dev/null)
    [ -z "$p_in" ] && { p_in=15; p_out=75; p_cr=1.50; p_cw=18.75; }
fi

# token counts (live window)
new_fmt=$(fmt_tok "${cu_new:-0}")
cache_tok=$(( ${cu_cread:-0} + ${cu_cwrite:-0} ))
cache_fmt=$(fmt_tok "$cache_tok")
out_fmt=$(fmt_tok "${cu_out:-0}")
sum_tok=$(( ${cu_new:-0} + cache_tok + ${cu_out:-0} ))
sum_fmt=$(fmt_tok "$sum_tok")
win_fmt=$(fmt_tok "$ctx_window_size")
ctx_fmt=$(fmt_tok "$current_ctx")

# per-category $ for THIS turn
read d_in d_out d_cache d_tot < <(LC_NUMERIC=C awk \
    -v n="${cu_new:-0}" -v o="${cu_out:-0}" -v cr="${cu_cread:-0}" -v cw="${cu_cwrite:-0}" \
    -v pi="$p_in" -v po="$p_out" -v pcr="$p_cr" -v pcw="$p_cw" \
    'BEGIN{di=n/1e6*pi; dou=o/1e6*po; dc=cr/1e6*pcr+cw/1e6*pcw; printf "%.2f %.2f %.2f %.2f", di, dou, dc, di+dou+dc}')

# cache hit rate + colors
total_in=$(( ${cu_new:-0} + cache_tok ))
if [ "$total_in" -gt 0 ]; then cache_hit=$(( ${cu_cread:-0} * 100 / total_in )); else cache_hit=0; fi
if [ "$cache_hit" -ge 80 ]; then cache_color="32"; elif [ "$cache_hit" -ge 40 ]; then cache_color="33"; else cache_color="90"; fi
if [ "$exceeds_200k" = "true" ] && [ "$ctx_window_size" -le 200000 ]; then pct_color="31"
elif [ "$ctx_percent" -ge 90 ]; then pct_color="31"; elif [ "$ctx_percent" -ge 50 ]; then pct_color="33"; else pct_color="32"; fi

OUT+="\033[37m|\033[0m"
OUT+=" \033[90m${last_reset_ts}\033[0m"
# Tokens block
OUT+=" \033[37m│\033[0m \033[1;37mTok\033[0m"
OUT+=" \033[36mIn:${new_fmt}\033[0m"
OUT+=" \033[34mCache:${cache_fmt}\033[0m"
OUT+=" \033[36mOut:${out_fmt}\033[0m"
OUT+=" \033[90mΣ${sum_fmt}\033[0m"
# $ block  (order per spec: In, Out, Cache, Total)
OUT+=" \033[37m│\033[0m \033[1;32m\$\033[0m"
OUT+=" \033[32mIn:${d_in}\033[0m"
OUT+=" \033[32mOut:${d_out}\033[0m"
OUT+=" \033[32mCache:${d_cache}\033[0m"
OUT+=" \033[${cost_color}mΣ${d_tot}\033[0m"
# Ctx / cache block
OUT+=" \033[37m│\033[0m"
OUT+=" \033[${pct_color}mCtx:${ctx_fmt}/${win_fmt}(${ctx_percent}%)\033[0m"
OUT+=" \033[${cache_color}mCache:${cache_hit}%\033[0m"
# User/Agent idle age: how long ago the last user prompt / last agent action landed.
OUT+=" \033[90mUser:${prompt_age}\033[0m"
OUT+=" \033[90mAgent:${action_age}\033[0m"
# Rate limits (5h / 7d window %) — omitted when the field is absent from stdin.
if [ -n "$rl_5h" ] || [ -n "$rl_7d" ]; then
    rl_5h_disp="${rl_5h%.*}"; [ -z "$rl_5h_disp" ] && rl_5h_disp="N/A"
    rl_7d_disp="${rl_7d%.*}"; [ -z "$rl_7d_disp" ] && rl_7d_disp="N/A"
    OUT+=" \033[37m│\033[0m"
    OUT+=" \033[$(get_color "$rl_5h_disp")m5h:${rl_5h_disp}%\033[0m"
    OUT+=" \033[$(get_color "$rl_7d_disp")m7d:${rl_7d_disp}%\033[0m"
fi
OUT+=" \033[37m|\033[0m\n"

printf "%b" "$OUT"
