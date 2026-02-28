#!/usr/bin/env bash

# Read JSON input from stdin
input=$(cat)

# Extract values from JSON
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
model_id=$(echo "$input" | jq -r '.model.id')
transcript_path=$(echo "$input" | jq -r '.transcript_path')

# Debug: log input JSON to file (uncomment to debug)
# echo "$input" > /tmp/statusline_debug.json

# Note: Claude Code provides .cost.total_cost_usd but we calculate our own
# based on model-specific pricing for better accuracy

# Extract context status boolean
exceeds_200k=$(echo "$input" | jq -r '.exceeds_200k_tokens // false')

# Extract context window data from Claude Code JSON (Line 2 - current state)
ctx_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
ctx_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')

# Extract session totals from Claude Code JSON (Line 3 - cumulative usage)
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')

# Cache for session token parsing (expensive operation)
token_cache="/tmp/statusline_tokens_$(echo "$transcript_path" | md5sum | cut -c1-8).cache"
transcript_mtime=$(stat -c %Y "$transcript_path" 2>/dev/null || echo 0)
cache_mtime=$(stat -c %Y "$token_cache" 2>/dev/null || echo 0)

if [ "$transcript_mtime" -gt "$cache_mtime" ] 2>/dev/null; then
    if [ -f "$transcript_path" ]; then
        # Get session start timestamp
        session_start=$(grep -o '"timestamp":"[^"]*"' "$transcript_path" | head -1 | cut -d'"' -f4)

        # Parse session tokens using jq (handles duplicates by taking unique requestId)
        # Extract: input_tokens, cache_creation, cache_read, output_tokens
        session_tokens=$(jq -s '
            [.[] | select(.type == "assistant" and .message.usage != null) |
             {reqId: .requestId, usage: .message.usage}] |
            group_by(.reqId) |
            map(last) |
            map(.usage) |
            {
                input: (map(.input_tokens // 0) | add),
                cache_create: (map(.cache_creation_input_tokens // 0) | add),
                cache_read: (map(.cache_read_input_tokens // 0) | add),
                output: (map(.output_tokens // 0) | add)
            }
        ' "$transcript_path" 2>/dev/null || echo '{"input":0,"cache_create":0,"cache_read":0,"output":0}')

        sess_input=$(echo "$session_tokens" | jq -r '.input // 0')
        sess_cache_create=$(echo "$session_tokens" | jq -r '.cache_create // 0')
        sess_cache_read=$(echo "$session_tokens" | jq -r '.cache_read // 0')
        sess_output=$(echo "$session_tokens" | jq -r '.output // 0')

        echo "$session_start $sess_input $sess_cache_create $sess_cache_read $sess_output" > "$token_cache"
    else
        echo "unknown 0 0 0 0" > "$token_cache"
    fi
fi

# Read session data from cache
if [ -f "$token_cache" ]; then
    read session_start_ts sess_input sess_cache_create sess_cache_read sess_output < "$token_cache" 2>/dev/null
fi
[ -z "$session_start_ts" ] && session_start_ts="unknown"
[ -z "$sess_input" ] && sess_input=0
[ -z "$sess_cache_create" ] && sess_cache_create=0
[ -z "$sess_cache_read" ] && sess_cache_read=0
[ -z "$sess_output" ] && sess_output=0

# Calculate session totals
sess_in_total=$((sess_input + sess_cache_create))  # New input tokens
sess_cache_total=$((sess_cache_read))               # Cached tokens read

# Format session start date/time
if [ "$session_start_ts" != "unknown" ] && [ -n "$session_start_ts" ]; then
    # Convert ISO timestamp to local date/time (MM-DD HH:MM)
    session_date=$(date -d "$session_start_ts" "+%m-%d %H:%M" 2>/dev/null || echo "$session_start_ts")
else
    session_date="unknown"
fi

# Context window size (200K for most Claude models)
ctx_window_size=200000

# Calculate current context usage (approximate - last request's context)
# Get the most recent cache_read value as it represents current context size
if [ -f "$transcript_path" ]; then
    current_ctx=$(grep -o '"cache_read_input_tokens":[0-9]*' "$transcript_path" | tail -1 | cut -d: -f2)
    [ -z "$current_ctx" ] && current_ctx=0
else
    current_ctx=0
fi

# === Context Reset Detection ===
ctx_state_file="/tmp/statusline_ctx_state_$(echo "$transcript_path" | md5sum | cut -c1-8).dat"
ctx_reset_file="/tmp/statusline_ctx_reset_$(echo "$transcript_path" | md5sum | cut -c1-8).dat"

# Read previous context state
prev_ctx=0
prev_exceeds="false"
if [ -f "$ctx_state_file" ]; then
    read prev_ctx prev_exceeds < "$ctx_state_file" 2>/dev/null
fi
[ -z "$prev_ctx" ] && prev_ctx=0
[ -z "$prev_exceeds" ] && prev_exceeds="false"

# Detect context reset:
# 1. Context dropped by more than 50% (significant compaction)
# 2. Or exceeds_200k went from true to false
ctx_reset_detected="false"
if [ "$prev_ctx" -gt 50000 ] && [ "$current_ctx" -gt 0 ]; then
    drop_threshold=$((prev_ctx / 2))
    if [ "$current_ctx" -lt "$drop_threshold" ]; then
        ctx_reset_detected="true"
    fi
fi
if [ "$prev_exceeds" = "true" ] && [ "$exceeds_200k" = "false" ]; then
    ctx_reset_detected="true"
fi

# Log reset if detected
if [ "$ctx_reset_detected" = "true" ]; then
    echo "$(date -Iseconds) $prev_ctx $current_ctx" >> "$ctx_reset_file"
fi

# Save current state for next comparison
echo "$current_ctx $exceeds_200k" > "$ctx_state_file"

# Get last reset timestamp
last_reset_ts="never"
if [ -f "$ctx_reset_file" ]; then
    last_reset_line=$(tail -1 "$ctx_reset_file" 2>/dev/null)
    if [ -n "$last_reset_line" ]; then
        last_reset_iso=$(echo "$last_reset_line" | cut -d' ' -f1)
        last_reset_ts=$(date -d "$last_reset_iso" "+%m-%d %H:%M" 2>/dev/null || echo "$last_reset_iso")
    fi
fi

# Model pricing ratios (per million tokens)
# Used to split total_cost between input and output
case "$model_id" in
    *opus*)
        price_input=15.00      # $15/MTok
        price_output=75.00     # $75/MTok
        ;;
    *sonnet*)
        price_input=3.00       # $3/MTok
        price_output=15.00     # $15/MTok
        ;;
    *haiku*)
        price_input=0.80       # $0.80/MTok
        price_output=4.00      # $4/MTok
        ;;
    *)
        # Default to sonnet pricing
        price_input=3.00
        price_output=15.00
        ;;
esac

# Calculate session costs based on actual token usage and model pricing
# Input cost = (input_tokens * base_rate + cache_create * 1.25x + cache_read * 0.1x) / 1M
# Output cost = output_tokens * output_rate / 1M
sess_cost_in=$(LC_NUMERIC=C awk "BEGIN {
    input = ${sess_input:-0}
    cache_create = ${sess_cache_create:-0}
    cache_read = ${sess_cache_read:-0}
    p_in = ${price_input:-3}

    # cache_create is 1.25x input price, cache_read is 0.1x input price
    cost = (input * p_in + cache_create * p_in * 1.25 + cache_read * p_in * 0.1) / 1000000
    printf \"%.2f\", cost
}")

sess_cost_out=$(LC_NUMERIC=C awk "BEGIN {
    output = ${sess_output:-0}
    p_out = ${price_output:-15}

    cost = output * p_out / 1000000
    printf \"%.2f\", cost
}")

# Extract full model name (opus-4-5, sonnet-4, haiku-3-5, etc)
model_name=$(echo "$model_id" | sed -E 's/^claude-//' | sed -E 's/-([0-9]{8})$//')
if [ -z "$model_name" ]; then
    model_name="unknown"
fi

# Extract session ID from JSON input
session_id=$(echo "$input" | jq -r '.session_id // empty')
# Fallback: extract from transcript path (.../sessions/<id>/transcript.jsonl)
if [ -z "$session_id" ]; then
    session_id=$(basename "$(dirname "$transcript_path")" 2>/dev/null)
fi
session_short="${session_id:0:8}"

# MCP server status - count configured servers from config files
mcp_configured=0
if [ -f "$HOME/.mcp.json" ]; then
    n=$(jq '.mcpServers // {} | keys | length' "$HOME/.mcp.json" 2>/dev/null)
    [ -n "$n" ] && mcp_configured=$((mcp_configured + n))
fi
if [ -f "${cwd}/.mcp.json" ]; then
    n=$(jq '.mcpServers // {} | keys | length' "${cwd}/.mcp.json" 2>/dev/null)
    [ -n "$n" ] && mcp_configured=$((mcp_configured + n))
fi
if [ "$mcp_configured" -gt 0 ]; then
    mcp_color="32"  # green
else
    mcp_color="90"  # dim
fi

# Format token count (K for thousands, M for millions)
format_tokens() {
    local tokens=$1
    if [ "$tokens" -ge 1000000 ]; then
        echo "$((tokens / 1000000))M"
    elif [ "$tokens" -ge 1000 ]; then
        echo "$((tokens / 1000))K"
    else
        echo "$tokens"
    fi
}

# Calculate context percentage (current context / 200K window)
if [ "$current_ctx" -gt 0 ] && [ "$ctx_window_size" -gt 0 ]; then
    ctx_percent=$((current_ctx * 100 / ctx_window_size))
else
    ctx_percent=0
fi

# Determine context status and color based on percentage
if [ "$exceeds_200k" = "true" ] || [ "$ctx_percent" -ge 95 ]; then
    ctx_color="31"  # red - compacting imminent
elif [ "$ctx_percent" -ge 80 ]; then
    ctx_color="33"  # yellow - approaching limit
elif [ "$ctx_percent" -ge 50 ]; then
    ctx_color="33"  # yellow
else
    ctx_color="32"  # green - plenty of room
fi

# Get current date and time (YYYY-MM-DD HH:MM:SS)
timestamp=$(date +"%Y-%m-%d %H:%M:%S")

# Get user@host information
user_host="$(whoami)@$(hostname -s)"

# Get current directory name (basename only)
current_dir=$(basename "$cwd")

# Get comprehensive git information
git_branch=""
git_commit=""
git_status_icons=""
git_stash=""

if cd "$cwd" 2>/dev/null && git rev-parse --git-dir > /dev/null 2>&1; then
    # Get branch name
    branch=$(git -c core.useBuiltinFSMonitor=false -c core.useReplaceRefs=false branch --show-current 2>/dev/null)
    if [ -n "$branch" ]; then
        git_branch="${branch}"
    else
        # Detached HEAD - show commit hash
        git_branch=$(git -c core.useBuiltinFSMonitor=false rev-parse --short HEAD 2>/dev/null)
    fi

    # Get short commit hash
    git_commit=$(git -c core.useBuiltinFSMonitor=false rev-parse --short HEAD 2>/dev/null)

    # Check if working tree is dirty (modified files)
    if ! git -c core.useBuiltinFSMonitor=false -c core.useReplaceRefs=false diff-index --quiet HEAD -- 2>/dev/null; then
        git_status_icons="${git_status_icons}*"
    fi

    # Check for staged changes
    if ! git -c core.useBuiltinFSMonitor=false diff-index --quiet --cached HEAD -- 2>/dev/null; then
        git_status_icons="${git_status_icons}+"
    fi

    # Check for untracked files
    if [ -n "$(git -c core.useBuiltinFSMonitor=false ls-files --others --exclude-standard 2>/dev/null | head -1)" ]; then
        git_status_icons="${git_status_icons}?"
    fi

    # Get ahead/behind commits
    upstream=$(git -c core.useBuiltinFSMonitor=false rev-parse --abbrev-ref @{upstream} 2>/dev/null)
    if [ -n "$upstream" ]; then
        ahead=$(git -c core.useBuiltinFSMonitor=false rev-list --count @{upstream}..HEAD 2>/dev/null)
        behind=$(git -c core.useBuiltinFSMonitor=false rev-list --count HEAD..@{upstream} 2>/dev/null)

        if [ "$ahead" -gt 0 ]; then
            git_status_icons="${git_status_icons}↑${ahead}"
        fi
        if [ "$behind" -gt 0 ]; then
            git_status_icons="${git_status_icons}↓${behind}"
        fi
    fi

    # Get stash count
    stash_count=$(git -c core.useBuiltinFSMonitor=false stash list 2>/dev/null | wc -l)
    if [ "$stash_count" -gt 0 ]; then
        git_stash="≡${stash_count}"
    fi
fi

# Function to get color based on percentage threshold
get_color() {
    local percent=$1
    if [ "$percent" = "N/A" ]; then
        echo "90"  # dim gray for N/A
    elif [ "$percent" -ge 80 ]; then
        echo "31"  # red
    elif [ "$percent" -ge 50 ]; then
        echo "33"  # yellow
    else
        echo "32"  # green
    fi
}

# Get RAM usage percentage
mem_info=$(free | grep Mem)
mem_total=$(echo "$mem_info" | awk '{print $2}')
mem_used=$(echo "$mem_info" | awk '{print $3}')
mem_percent=$(awk "BEGIN {printf \"%.0f\", ($mem_used/$mem_total)*100}")
mem_color=$(get_color "$mem_percent")

# Get CPU usage percentage (optimized with shorter sleep)
cpu_percent=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else printf "%.0f", (($2+$4-u1) * 100 / (t-t1))}' <(grep 'cpu ' /proc/stat) <(sleep 0.1; grep 'cpu ' /proc/stat))
cpu_color=$(get_color "$cpu_percent")

# Get disk usage percentage (/data on Android/Termux, / on desktop)
if [ -d "/data/data/com.termux.nix" ]; then
    disk_percent=$(df /data | tail -n 1 | awk '{print $5}' | sed 's/%//')
else
    disk_percent=$(df / | tail -n 1 | awk '{print $5}' | sed 's/%//')
fi
disk_color=$(get_color "$disk_percent")

# Get VRAM usage percentage
vram_percent="N/A"
if command -v nvidia-smi &>/dev/null; then
    # NVIDIA GPU detection
    vram_info=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1)
    if [ -n "$vram_info" ]; then
        vram_used=$(echo "$vram_info" | awk -F',' '{print $1}')
        vram_total=$(echo "$vram_info" | awk -F',' '{print $2}')
        if [ -n "$vram_used" ] && [ -n "$vram_total" ] && [ "$vram_total" != "0" ]; then
            vram_percent=$(awk "BEGIN {printf \"%.0f\", ($vram_used/$vram_total)*100}")
        fi
    fi
elif command -v rocm-smi &>/dev/null; then
    # AMD GPU detection (ROCm)
    vram_info=$(rocm-smi --showmeminfo vram --csv 2>/dev/null | grep -v "GPU" | head -n 1)
    if [ -n "$vram_info" ]; then
        vram_used=$(echo "$vram_info" | awk -F',' '{print $2}')
        vram_total=$(echo "$vram_info" | awk -F',' '{print $3}')
        if [ -n "$vram_used" ] && [ -n "$vram_total" ] && [ "$vram_total" != "0" ]; then
            vram_percent=$(awk "BEGIN {printf \"%.0f\", ($vram_used/$vram_total)*100}")
        fi
    fi
elif command -v radeontop &>/dev/null; then
    # AMD GPU detection (radeontop fallback)
    vram_info=$(radeontop -d - -l 1 2>/dev/null | grep -o "vram [0-9.]*%" | head -n 1)
    if [ -n "$vram_info" ]; then
        vram_percent=$(echo "$vram_info" | grep -o "[0-9]*" | head -n 1)
    fi
elif command -v intel_gpu_top &>/dev/null; then
    # Intel GPU detection - note: intel_gpu_top doesn't directly report VRAM usage
    # This is a placeholder as Intel integrated GPUs share system RAM
    # We'll just mark as N/A for now
    vram_percent="N/A"
fi
vram_color=$(get_color "$vram_percent")

# Find ip command (try common locations)
IP_CMD=""
for p in /sbin/ip /usr/sbin/ip /bin/ip $HOME/.nix-profile/bin/ip /run/current-system/sw/bin/ip; do
    [ -x "$p" ] && IP_CMD="$p" && break
done

# Check WireGuard mesh status (quick check)
mesh_status="down"
mesh_color="31"  # red
mesh_ip=""  # Will be set to IP or "none" later

# Primary check: Can we reach the mesh network? (works on desktop + Termux/Android WireGuard)
# Use curl instead of ping - more reliable on Termux (ping has setuid issues)
if timeout 1 curl -s http://10.0.0.1:80 >/dev/null 2>&1; then
    mesh_status="up"
    mesh_color="32"  # green

    # Try to get our mesh IP from wg0 interface (desktop/direct WireGuard)
    if [ -n "$IP_CMD" ] && $IP_CMD link show wg0 &>/dev/null 2>&1; then
        mesh_ip=$($IP_CMD -4 addr show wg0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    elif [ -d "/sys/class/net/wg0" ]; then
        # Fallback: sysfs
        mesh_ip=$(ip addr show wg0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    fi

    # If still empty, try WireGuard config file (Termux/Android WireGuard app)
    WG_CONF="${HOME}/.config/wireguard/wg0.conf"
    if [ -z "$mesh_ip" ] && [ -f "$WG_CONF" ]; then
        mesh_ip=$(grep -i "^Address" "$WG_CONF" 2>/dev/null | awk '{print $3}' | cut -d'/' -f1)
    fi

    [ -z "$mesh_ip" ] && mesh_ip="none"
fi

# Get private IP (local network) - try multiple methods
private_ip=""
if [ -n "$IP_CMD" ]; then
    private_ip=$($IP_CMD route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1)
fi
# Fallback: parse from hostname or network interfaces
if [ -z "$private_ip" ]; then
    private_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
# Filter out localhost and mesh IPs
if [ "$private_ip" = "127.0.0.1" ] || [ -z "$private_ip" ] || [[ "$private_ip" == 10.0.0.* ]]; then
    # Try reading from /proc/net interfaces
    private_ip=$(cat /proc/net/fib_trie 2>/dev/null | grep -oP '(?<=\|-- )\d+\.\d+\.\d+\.\d+' | grep -v "^127\." | grep -v "^10\.0\.0\." | head -1)
fi
# Final fallback: Use Python socket method (works on Termux/Android)
if [ -z "$private_ip" ] || [ "$private_ip" = "127.0.0.1" ] || [[ "$private_ip" == 10.0.0.* ]]; then
    private_ip=$(python3 -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('8.8.8.8',80)); print(s.getsockname()[0]); s.close()" 2>/dev/null)
fi
[ -z "$private_ip" ] && private_ip="none"

# Get public IP (with 2 second timeout)
public_ip=$(curl -s --max-time 2 ifconfig.me 2>/dev/null)
[ -z "$public_ip" ] && public_ip="..."

# Build status line with FULL information — buffered to prevent word-by-word rendering
# Format: HH:MM:SS  opus-4-5 diego@surface directory  branch@hash*+?↑↓ ≡stash CTX:tokens RAM:% CPU:% Disk:% VRAM:%
OUT=""

# === LINE 1: | date | model session mcp_status | host repo branch | ===
OUT+="\033[37m|\033[0m"
OUT+=" \033[90m${timestamp}\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[35m\033[0m \033[35m${model_name}\033[0m"
OUT+=" \033[90m${session_short}\033[0m"
OUT+=" \033[${mcp_color}mMCP:${mcp_configured}\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[36m${user_host}\033[0m"
OUT+=" \033[34m$(basename "$cwd")\033[0m"

if [ -n "$git_branch" ]; then
    OUT+=" \033[33m\033[0m \033[33m${git_branch}\033[0m"
    [ -n "$git_commit" ] && OUT+="\033[33m@${git_commit}\033[0m"
    [ -n "$git_status_icons" ] && OUT+="\033[31m${git_status_icons}\033[0m"
    [ -n "$git_stash" ] && OUT+=" \033[35m${git_stash}\033[0m"
fi
OUT+=" \033[37m|\033[0m"
OUT+="\n"

# === LINE 2: | System Metrics | Network | ===
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
OUT+=" \033[37m|\033[0m"
OUT+="\n"

# === LINE 3: Context Window | Session Usage ===
ctx_current_fmt=$(format_tokens "$current_ctx")
ctx_input_fmt=$(format_tokens "$ctx_input")
ctx_output_fmt=$(format_tokens "$ctx_output")
sess_in_fmt=$(format_tokens "$sess_in_total")
sess_cache_fmt=$(format_tokens "$sess_cache_total")
sess_out_fmt=$(format_tokens "$sess_output")

ctx_cost_in=$(LC_NUMERIC=C awk "BEGIN {printf \"%.2f\", ${ctx_input:-0} * ${price_input:-3} / 1000000}")
ctx_cost_out=$(LC_NUMERIC=C awk "BEGIN {printf \"%.2f\", ${ctx_output:-0} * ${price_output:-15} / 1000000}")

OUT+="\033[37m|\033[0m"
OUT+=" \033[90m${last_reset_ts}\033[0m"
if [ "$exceeds_200k" = "true" ]; then
    OUT+="\033[31mCTX:${ctx_current_fmt}/200K(⚠)\033[0m"
else
    OUT+="\033[${ctx_color}mCTX:${ctx_current_fmt}/200K(${ctx_percent}%)\033[0m"
fi
OUT+=" \033[36mIn:${ctx_input_fmt}\033[0m"
OUT+=" \033[36mOut:${ctx_output_fmt}\033[0m"
OUT+=" \033[32m\$${ctx_cost_in:-0.00}/\$${ctx_cost_out:-0.00}\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[90m${session_date}\033[0m"
OUT+=" \033[36mIn:${sess_in_fmt}\033[0m"
OUT+=" \033[36mCache:${sess_cache_fmt}\033[0m"
OUT+=" \033[36mOut:${sess_out_fmt}\033[0m"

sess_cost_total_cents=$(LC_NUMERIC=C awk "BEGIN {printf \"%.0f\", (${sess_cost_in:-0} + ${sess_cost_out:-0}) * 100}")
[ -z "$sess_cost_total_cents" ] && sess_cost_total_cents=0
if [ "$sess_cost_total_cents" -ge 1000 ]; then
    cost_color="31"
elif [ "$sess_cost_total_cents" -ge 500 ]; then
    cost_color="33"
else
    cost_color="32"
fi
OUT+=" \033[${cost_color}m\$${sess_cost_in:-0.00}/\$${sess_cost_out:-0.00}\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+="\n"

# Print everything at once (atomic render — no word-by-word flickering)
printf "%b" "$OUT"
