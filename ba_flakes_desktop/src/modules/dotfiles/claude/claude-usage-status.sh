#!/usr/bin/env bash
# claude-usage-status.sh — active 5h billing-window token/cost breakdown for
# the statusline, sourced from `ccusage` (reads local ~/.claude/projects
# transcripts across ALL projects — no network call to any of our infra).
#
# `ccusage` itself takes ~2-3s per invocation (npx cold-start + transcript
# scan), too slow for a 1s-refresh statusline — same problem claude-mcp-
# status.sh solves for `claude mcp list`. Same fix: cache + detached lazy
# refresh. TTL 30s (the window barely moves faster than that).
#
# Output (ansi): Usage5h[New:1K($0) CchW:4M($73) CchR:41M($62) Out:161K($24) Σ46M($108) rem:218m]
#   Emits nothing if ccusage errors, no active block, or cache not yet warm.
set -u

TTL=30
LOCK_TTL=30
CACHE="${TMPDIR:-/tmp}/claude-usage-status.cache"
LOCK="${TMPDIR:-/tmp}/claude-usage-status.refresh.lock"
CCUSAGE_VERSION="20.0.19"   # pinned: unpinned `npx ccusage@latest` re-resolves over the network every call

# --- Hidden mode: the detached refresher ($0 --refresh) --------------------
if [ "${1:-}" = "--refresh" ]; then
  command -v npx >/dev/null 2>&1 || { rmdir "$LOCK" 2>/dev/null; exit 0; }
  raw=$(timeout 15 npx --yes "ccusage@${CCUSAGE_VERSION}" blocks --active --json 2>/dev/null)
  seg=""
  if [ -n "$raw" ] && command -v jq >/dev/null 2>&1; then
    seg=$(printf '%s' "$raw" | jq -r '
      (.blocks[]? | select(.isActive == true)) as $b |
      if $b == null then empty else
        ($b.tokenCounts.inputTokens // 0) as $in |
        ($b.tokenCounts.cacheCreationInputTokens // 0) as $cw |
        ($b.tokenCounts.cacheReadInputTokens // 0) as $cr |
        ($b.tokenCounts.outputTokens // 0) as $out |
        ($b.totalTokens // 0) as $sum |
        ($b.costUSD // 0) as $cost |
        ($b.projection.remainingMinutes // 0) as $rem |
        [$in, $cw, $cr, $out, $sum, $cost, $rem] | @tsv
      end' 2>/dev/null)
  fi
  tmp="$CACHE.$$"
  printf '%s' "$seg" > "$tmp" && mv -f "$tmp" "$CACHE"
  rmdir "$LOCK" 2>/dev/null
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

# --- Lazy refresh: fire at most one detached background job when stale ---
need=false
if [ ! -f "$CACHE" ]; then
  need=true
else
  now=$(date +%s 2>/dev/null || echo 0)
  mtime=$(stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  [ $((now - mtime)) -ge "$TTL" ] && need=true
fi
if [ "$need" = true ] && command -v npx >/dev/null 2>&1; then
  if [ -d "$LOCK" ]; then
    lmtime=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)
    [ $(( $(date +%s 2>/dev/null || echo 0) - lmtime )) -ge "$LOCK_TTL" ] && rmdir "$LOCK" 2>/dev/null
  fi
  if mkdir "$LOCK" 2>/dev/null; then
    if command -v setsid >/dev/null 2>&1; then
      setsid bash "$0" --refresh </dev/null >/dev/null 2>&1 &
    else
      bash "$0" --refresh </dev/null >/dev/null 2>&1 &
    fi
  fi
fi

[ -f "$CACHE" ] || exit 0
line=$(cat "$CACHE" 2>/dev/null)
[ -z "$line" ] && exit 0
IFS=$'\t' read -r in cw cr out sum cost rem <<<"$line"
[ -z "${sum:-}" ] && exit 0

fmt_tok() {
  local t=$1
  if [ "$t" -ge 1000000 ]; then echo "$((t / 1000000))M"
  elif [ "$t" -ge 1000 ]; then echo "$((t / 1000))K"
  else echo "$t"; fi
}
fmt_usd() { LC_NUMERIC=C awk -v v="$1" 'BEGIN{printf "%.0f", v}'; }

# ccusage only reports a single blended costUSD per block, not a per-category
# split ($ next to New/CchW/CchR/Out like LINE 4's per-session breakdown) —
# so this row shows raw token counts + one total $, not four separate costs.
printf 'Usage5h[New:%s CchW:%s CchR:%s Out:%s \xce\xa3%s($%s) rem:%sm]' \
  "$(fmt_tok "${in:-0}")" \
  "$(fmt_tok "${cw:-0}")" \
  "$(fmt_tok "${cr:-0}")" \
  "$(fmt_tok "${out:-0}")" \
  "$(fmt_tok "${sum:-0}")" "$(fmt_usd "${cost:-0}")" \
  "${rem:-0}"
