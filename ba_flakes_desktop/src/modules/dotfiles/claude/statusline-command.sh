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
    @sh "session_name=\(.session_name // empty)"
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
mins_since=$(( (now_epoch - last_epoch) / 60 ))
echo "$current_ctx $exceeds_200k $last_epoch" > "$ctx_state_file"

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

# ponytail: everything below stubbed — all heavy probes disabled (MCP/plugins/hooks/RAM/CPU/disk/mesh/tokens/cost)
# Restore individual blocks from git history when needed.

# === BUILD OUTPUT — LINE 1 only: model@effort | session@name ===
OUT=""
OUT+="\033[37m|\033[0m"
OUT+=" \033[35m${model_name}\033[0m"
[ -n "$effort_level" ] && OUT+=" \033[90m@\033[0m \033[36m${effort_level}\033[0m"
OUT+=" \033[37m|\033[0m"
OUT+=" \033[90m${session_short}\033[0m"
[ -n "$session_name" ] && OUT+=" \033[90m@\033[0m \033[37m${session_name_disp}\033[0m"
OUT+=" \033[37m|\033[0m\n"
printf "%b" "$OUT"
