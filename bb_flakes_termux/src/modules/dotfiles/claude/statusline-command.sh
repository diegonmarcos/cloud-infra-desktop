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
    @sh "session_cost=\(.cost.total_cost_usd // 0)",
    @sh "session_id=\(.session_id // empty)"
')"

# Fallback session ID from transcript path
[ -z "$session_id" ] && session_id=$(basename "$(dirname "$transcript_path")" 2>/dev/null)
session_short="${session_id:0:8}"

# Model name (strip claude- prefix and date suffix)
model_name=$(echo "$model_id" | sed -E 's/^claude-//; s/-([0-9]{8})$//')
[ -z "$model_name" ] && model_name="unknown"

# Context window (200K) — use ctx_input as current context size
ctx_window_size=200000
current_ctx=${ctx_input:-0}
if [ "$current_ctx" -gt 0 ] && [ "$ctx_window_size" -gt 0 ]; then
    ctx_percent=$((current_ctx * 100 / ctx_window_size))
else
    ctx_percent=0
fi

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

# === Git info — DISABLED 2026-04-28 ===
# Git ops were costing 6+ CPU cores on large monorepos (~/git/cloud, ~/git/unix
# with rust target/, node_modules/). 9 git invocations per render: branch,
# rev-parse HEAD x2, diff-index x2, ls-files --others, rev-parse @{upstream},
# rev-list --count x2, stash list. Vars stay declared empty so downstream
# rendering at the status line below skips the git block entirely.
git_branch=""; git_commit=""; git_status_icons=""; git_stash=""
# if cd "$cwd" 2>/dev/null && git rev-parse --git-dir > /dev/null 2>&1; then
#     git_cache="/tmp/statusline_git_$(echo "$cwd" | md5sum | cut -c1-8).cache"
#     git_cache_age=$(( $(date +%s) - $(stat -c %Y "$git_cache" 2>/dev/null || echo 0) ))
#
#     if [ -f "$git_cache" ] && [ "$git_cache_age" -lt 10 ]; then
#         IFS='|' read git_branch git_commit git_status_icons git_stash < "$git_cache" 2>/dev/null
#     else
#         branch=$(git -c core.useBuiltinFSMonitor=false -c core.useReplaceRefs=false branch --show-current 2>/dev/null)
#         [ -n "$branch" ] && git_branch="$branch" || git_branch=$(git -c core.useBuiltinFSMonitor=false rev-parse --short HEAD 2>/dev/null)
#         git_commit=$(git -c core.useBuiltinFSMonitor=false rev-parse --short HEAD 2>/dev/null)
#
#         git -c core.useBuiltinFSMonitor=false -c core.useReplaceRefs=false diff-index --quiet HEAD -- 2>/dev/null || git_status_icons+="*"
#         git -c core.useBuiltinFSMonitor=false diff-index --quiet --cached HEAD -- 2>/dev/null || git_status_icons+="+"
#         [ -n "$(git -c core.useBuiltinFSMonitor=false ls-files --others --exclude-standard 2>/dev/null | head -1)" ] && git_status_icons+="?"
#
#         upstream=$(git -c core.useBuiltinFSMonitor=false rev-parse --abbrev-ref @{upstream} 2>/dev/null)
#         if [ -n "$upstream" ]; then
#             ahead=$(git -c core.useBuiltinFSMonitor=false rev-list --count @{upstream}..HEAD 2>/dev/null)
#             behind=$(git -c core.useBuiltinFSMonitor=false rev-list --count HEAD..@{upstream} 2>/dev/null)
#             [ "$ahead" -gt 0 ] && git_status_icons+="↑${ahead}"
#             [ "$behind" -gt 0 ] && git_status_icons+="↓${behind}"
#         fi
#
#         stash_count=$(git -c core.useBuiltinFSMonitor=false stash list 2>/dev/null | wc -l)
#         [ "$stash_count" -gt 0 ] && git_stash="≡${stash_count}"
#
#         echo "${git_branch}|${git_commit}|${git_status_icons}|${git_stash}" > "$git_cache"
#     fi
# fi

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
OUT+=" \033[${mcp_color}mMCP:${mcp_configured}\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[36m${user_host}\033[0m"
OUT+=" \033[34m$(basename "$cwd")\033[0m"

if [ -n "$git_branch" ]; then
    OUT+=" \033[33m${git_branch}\033[0m"
    [ -n "$git_commit" ] && OUT+="\033[33m@${git_commit}\033[0m"
    [ -n "$git_status_icons" ] && OUT+="\033[31m${git_status_icons}\033[0m"
    [ -n "$git_stash" ] && OUT+=" \033[35m${git_stash}\033[0m"
fi
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

# LINE 3: | last_reset CTX:used/200K(%) In:tok Out:tok $cost |
ctx_fmt=$(fmt_tok "$current_ctx")
in_fmt=$(fmt_tok "${ctx_input:-0}")
out_fmt=$(fmt_tok "${ctx_output:-0}")
OUT+="\033[37m|\033[0m"
OUT+=" \033[90m${last_reset_ts}\033[0m"
if [ "$exceeds_200k" = "true" ]; then
    OUT+=" \033[31mCTX:${ctx_fmt}/200K(⚠)\033[0m"
else
    OUT+=" \033[${ctx_color}mCTX:${ctx_fmt}/200K(${ctx_percent}%)\033[0m"
fi
OUT+=" \033[36mIn:${in_fmt}\033[0m"
OUT+=" \033[36mOut:${out_fmt}\033[0m"
cost_fmt=$(LC_NUMERIC=C awk "BEGIN {printf \"%.2f\", ${session_cost:-0}}")
OUT+=" \033[${cost_color}m\$${cost_fmt}\033[0m"
OUT+=" \033[37m|\033[0m\n"

printf "%b" "$OUT"
