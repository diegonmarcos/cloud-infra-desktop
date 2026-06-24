#!/usr/bin/env bash
# claude-mcp-status.sh — per-MCP online/offline icons for the statusline.
#
# Live status comes from `claude mcp list`, which HEALTH-CHECKS every server
# (spawns stdio servers / HTTP-GETs remote ones) and is SLOW — so it is NEVER
# run in the render hot path. Instead: a LAZY cache with a 15-min TTL. The
# statusline reads the cache instantly; when the cache is missing or stale, ONE
# non-blocking, lock-guarded background refresh is fired and the stale value is
# used for the current render.
#
# Output (ansi): MCP[●●○●…]  — one dot per CONFIGURED server, stable sorted
# order. ● green = connected, ○ grey = offline/pending/unknown. Emits nothing if
# no servers are configured; the statusline falls back to the plain count.
#
# Arg 1 (optional): project cwd, to also read its ./.mcp.json. Defaults to $PWD.
set -u

TTL=900                                            # 15 min
LOCK_TTL=120                                        # a refresh can't outlive timeout 60 + overhead
CACHE="${TMPDIR:-/tmp}/claude-mcp-status.cache"    # "name<TAB>on|off" per line
LOCK="${TMPDIR:-/tmp}/claude-mcp-status.refresh.lock"

cwd="${1:-$PWD}"
command -v jq >/dev/null 2>&1 || exit 0

# Configured server names (global + project), stable + de-duplicated.
servers=""
for f in "$HOME/.mcp.json" "$cwd/.mcp.json"; do
  [ -f "$f" ] && servers="$servers"$'\n'"$(jq -r '.mcpServers // {} | keys[]' "$f" 2>/dev/null)"
done
servers=$(printf '%s\n' "$servers" | sed '/^$/d' | sort -u)
[ -z "$servers" ] && exit 0

# --- Lazy refresh: fire at most one background `claude mcp list` when stale ---
need=false
if [ ! -f "$CACHE" ]; then
  need=true
else
  now=$(date +%s 2>/dev/null || echo 0)
  mtime=$(stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  [ $((now - mtime)) -ge "$TTL" ] && need=true
fi
if [ "$need" = true ] && command -v claude >/dev/null 2>&1; then
  # Reclaim a dead lock: a refresher that died before rmdir (statusline reaps the
  # backgrounded subshell, timeout kills it, session exits) would otherwise wedge
  # the lock forever and freeze the cache. A live refresh can't outlive LOCK_TTL.
  if [ -d "$LOCK" ]; then
    lmtime=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)
    [ $(( $(date +%s 2>/dev/null || echo 0) - lmtime )) -ge "$LOCK_TTL" ] && rmdir "$LOCK" 2>/dev/null
  fi
  # mkdir is atomic → exactly one refresher at a time (no stampede).
  if mkdir "$LOCK" 2>/dev/null; then
    (
      run="claude mcp list"
      command -v timeout >/dev/null 2>&1 && run="timeout 60 $run"
      tmp="$CACHE.$$"
      $run 2>/dev/null | while IFS= read -r line; do
        case "$line" in
          *:*)
            name=${line%%:*}; name=$(printf '%s' "$name" | tr -d '[:space:]')
            [ -z "$name" ] && continue
            case "$line" in
              *"✓"*|*[Cc]onnected*) printf '%s\t%s\n' "$name" "on" ;;
              *)                    printf '%s\t%s\n' "$name" "off" ;;
            esac ;;
        esac
      done > "$tmp" 2>/dev/null
      [ -s "$tmp" ] && mv -f "$tmp" "$CACHE" || rm -f "$tmp"
      rmdir "$LOCK" 2>/dev/null
    ) >/dev/null 2>&1 &
  fi
fi

# --- Render from cache (stale OK); uncached/unknown server → off ---
out=""
while IFS= read -r s; do
  [ -z "$s" ] && continue
  state="off"
  [ -f "$CACHE" ] && { c=$(awk -F'\t' -v n="$s" '$1==n {print $2; exit}' "$CACHE" 2>/dev/null); [ -n "$c" ] && state="$c"; }
  if [ "$state" = "on" ]; then out="$out\033[32m●\033[0m"; else out="$out\033[90m○\033[0m"; fi
done <<EOF
$servers
EOF

printf '%s' "MCP[$out]"
