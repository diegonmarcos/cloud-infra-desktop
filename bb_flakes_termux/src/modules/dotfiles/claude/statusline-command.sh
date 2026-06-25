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
    @sh "session_id=\(.session_id // empty)"
')"

# Fallback session ID from transcript path
[ -z "$session_id" ] && session_id=$(basename "$(dirname "$transcript_path")" 2>/dev/null)
session_short="${session_id:0:8}"

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

prev_ctx=0; prev_exceeds="false"
[ -f "$ctx_state_file" ] && read prev_ctx prev_exceeds < "$ctx_state_file" 2>/dev/null
[ -z "$prev_ctx" ] && prev_ctx=0
[ -z "$prev_exceeds" ] && prev_exceeds="false"

ctx_reset_detected="false"
if [ "$prev_ctx" -gt 50000 ] && [ "$current_ctx" -gt 0 ]; then
    [ "$current_ctx" -lt $((prev_ctx / 2)) ] && ctx_reset_detected="true"
fi
[ "$prev_exceeds" = "true" ] && [ "$exceeds_200k" = "false" ] && ctx_reset_detected="true"

[ "$ctx_reset_detected" = "true" ] && echo "$(date -Iseconds) $prev_ctx $current_ctx" >> "$ctx_reset_file"
echo "$current_ctx $exceeds_200k" > "$ctx_state_file"

last_reset_ts="never"
if [ -f "$ctx_reset_file" ]; then
    last_reset_line=$(tail -1 "$ctx_reset_file" 2>/dev/null)
    [ -n "$last_reset_line" ] && last_reset_ts=$(date -d "$(echo "$last_reset_line" | cut -d' ' -f1)" "+%m-%d %H:%M" 2>/dev/null || echo "?")
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

# Per-MCP online/offline icons (lazy 15-min cache) + plugin status PL[...].
# Both helpers emit literal \033 escapes; the final `printf %b` renders them.
mcp_seg=$(bash "$HOME/.claude/claude-mcp-status.sh" "$cwd" 2>/dev/null)
plugins_seg=$(bash "$HOME/.claude/claude-plugins-status.sh" --format ansi 2>/dev/null)
hooks_seg=$(bash "$HOME/.claude/claude-hooks-status.sh" --format ansi 2>/dev/null)

# Timestamp, user, dir
timestamp=$(date +"%Y-%m-%d %H:%M:%S")
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

# === Expensive probes — DISABLED 2026-05-01 ===
# Reason: Termux has no GPU (nvidia-smi wasted) and the mesh/public-IP curls
# fired on every status render — external network calls per refresh. Private-IP
# probe also disabled because it forks `ip route get` + reads /proc/net/fib_trie
# every render despite the IP barely changing on a phone session.
# Static stubs preserve the rendering contract; vars below are read by the
# render block unchanged. To re-enable, restore from git history.
echo "N/A" > "$_async/vram"
echo "off 90 —" > "$_async/mesh"
echo "—" > "$_async/pip"
echo "—" > "$_async/pub"

# Wait for the only remaining background job (CPU sample, bounded by sleep 0.1)
wait 2>/dev/null

# Read async results
cpu_percent=$(cat "$_async/cpu" 2>/dev/null); [ -z "$cpu_percent" ] && cpu_percent=0
vram_percent=$(cat "$_async/vram" 2>/dev/null); [ -z "$vram_percent" ] && vram_percent="N/A"
read mesh_status mesh_color mesh_ip < "$_async/mesh" 2>/dev/null
[ -z "$mesh_status" ] && mesh_status="down" && mesh_color="31"
private_ip=$(cat "$_async/pip" 2>/dev/null); [ -z "$private_ip" ] && private_ip="none"
public_ip=$(cat "$_async/pub" 2>/dev/null); [ -z "$public_ip" ] && public_ip="..."
rm -rf "$_async"

# Colors
mem_color=$(get_color "$mem_percent")
cpu_color=$(get_color "$cpu_percent")
disk_color=$(get_color "$disk_percent")
vram_color=$(get_color "$vram_percent")

# === BUILD OUTPUT ===
OUT=""

# LINE 1: | date | model session mcp | host dir branch |
OUT+="\033[37m|\033[0m"
OUT+=" \033[90m${timestamp}\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[35m${model_name}\033[0m"
OUT+=" \033[90m${session_short}\033[0m"
if [ -n "$mcp_seg" ]; then OUT+=" ${mcp_seg}"; else OUT+=" \033[${mcp_color}mMCP:${mcp_configured}\033[0m"; fi
[ -n "$plugins_seg" ] && OUT+=" ${plugins_seg}"
[ -n "$hooks_seg" ] && OUT+=" ${hooks_seg}"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[36m${user_host}\033[0m"
OUT+=" \033[37m|\033[0m"
# repo/folder (collapse to just folder when it equals the repo root, or no repo)
folder=$(basename "$cwd")
if [ -n "$git_repo" ] && [ "$git_repo" != "$folder" ]; then
    OUT+=" \033[34m${git_repo}/${folder}\033[0m"
else
    OUT+=" \033[34m${folder}\033[0m"
fi
[ -n "$git_branch" ] && OUT+=" \033[90m@\033[0m \033[33m${git_branch}\033[0m"
OUT+=" \033[37m|\033[0m\n"

# LINE 2: | RAM CPU Disk VRAM | Mesh M:ip P:ip Pub:ip |
OUT+="\033[37m|\033[0m"
OUT+=" \033[${mem_color}mRAM:${mem_percent}%\033[0m"
OUT+=" \033[${cpu_color}mCPU:${cpu_percent}%\033[0m"
OUT+=" \033[${disk_color}mDisk:${disk_percent}%\033[0m"
OUT+=" \033[${vram_color}mVRAM:${vram_percent}%\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[${mesh_color}mMesh:${mesh_status}\033[0m"
OUT+=" \033[36mM:${mesh_ip}\033[0m"
OUT+=" \033[36mP:${private_ip}\033[0m"
OUT+=" \033[36mPub:${public_ip}\033[0m"
OUT+=" \033[37m|\033[0m\n"

# LINE 3: | last_reset CTX:used/<win>(%) ⚡cache% In:new +cache Out Σtotal $cost |
# Token breakdown is the LIVE context window (context_window.current_usage),
# straight from stdin — spawn-free. $ is cumulative session (cost.total_cost_usd).
win_fmt=$(fmt_tok "$ctx_window_size")
ctx_fmt=$(fmt_tok "$current_ctx")
new_fmt=$(fmt_tok "${cu_new:-0}")
cache_tok=$(( ${cu_cread:-0} + ${cu_cwrite:-0} ))   # cache read + write
cache_fmt=$(fmt_tok "$cache_tok")
out_fmt=$(fmt_tok "${cu_out:-0}")
sum_tok=$(( ${cu_new:-0} + cache_tok + ${cu_out:-0} ))
sum_fmt=$(fmt_tok "$sum_tok")
# cache hit rate = cache_read / total_input (input side only)
total_in=$(( ${cu_new:-0} + cache_tok ))
if [ "$total_in" -gt 0 ]; then cache_hit=$(( ${cu_cread:-0} * 100 / total_in )); else cache_hit=0; fi
if [ "$cache_hit" -ge 80 ]; then cache_color="32"; elif [ "$cache_hit" -ge 40 ]; then cache_color="33"; else cache_color="90"; fi

OUT+="\033[37m|\033[0m"
OUT+=" \033[90m${last_reset_ts}\033[0m"
if [ "$exceeds_200k" = "true" ] && [ "$ctx_window_size" -le 200000 ]; then
    OUT+=" \033[31mCTX:${ctx_fmt}/${win_fmt}(⚠)\033[0m"
else
    OUT+=" \033[${ctx_color}mCTX:${ctx_fmt}/${win_fmt}(${ctx_percent}%)\033[0m"
fi
OUT+=" \033[${cache_color}m⚡${cache_hit}%\033[0m"
OUT+=" \033[36mIn:${new_fmt}\033[0m"
OUT+=" \033[34m+cache:${cache_fmt}\033[0m"
OUT+=" \033[36mOut:${out_fmt}\033[0m"
OUT+=" \033[90mΣ${sum_fmt}\033[0m"
cost_fmt=$(LC_NUMERIC=C awk "BEGIN {c=${session_cost:-0}; printf (c>=1?\"%.2f\":\"%.4f\"), c}")
OUT+=" \033[${cost_color}m\$${cost_fmt}\033[0m"
OUT+=" \033[37m|\033[0m\n"

printf "%b" "$OUT"
