#!/usr/bin/env bash
# claude-plugins-status.sh — on/off status of registered Claude Code PLUGINS
# (NOT MCP servers). Data-driven: reads ~/.claude/claude-plugins.json; add a
# plugin by appending a JSON entry — no edits here.
#
# Usage: claude-plugins-status.sh [--format ansi|plain]
#   ansi  (default): compact statusline segment → PL[H● P●:full]
#                    ● green = on / ○ grey = off; flag_file plugins append mode.
#   plain          : uncolored, for the claude-superset banner → "Headroom:on Ponytail:full"
#
# detect.type:
#   env_set    → env var detect.env is non-empty
#   flag_file  → file detect.path (relative to config dir) exists;
#                detect.show_content=true appends its content (e.g. ponytail mode)
#
# Detection is deliberately spawn-free (env var + stat) so it is safe to call on
# every statusline render. One jq call parses the whole manifest.
set -u

fmt="ansi"; [ "${1:-}" = "--format" ] && fmt="${2:-ansi}"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MAN="$CFG/claude-plugins.json"

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$MAN" ] || exit 0

# One jq call → TSV: label \t icon \t type \t env \t path \t show_content.
# Absent optional fields get a "-" sentinel (not ""): tab is IFS-whitespace, so
# `read` would coalesce an empty middle column and shift every field left.
rows=$(jq -r '.plugins[] | [.label, .icon, .detect.type, (.detect.env // "-"), (.detect.path // "-"), (.detect.show_content // false)] | @tsv' "$MAN" 2>/dev/null) || exit 0
[ -z "$rows" ] && exit 0

ansi=""; plain=""
while IFS=$'\t' read -r label icon dtype env path show; do
  [ -z "$label" ] && continue
  [ "$env" = "-" ] && env=""
  [ "$path" = "-" ] && path=""
  on=false; detail=""
  case "$dtype" in
    env_set)
      [ -n "${!env:-}" ] && on=true ;;
    flag_file)
      if [ -f "$CFG/$path" ]; then
        on=true
        [ "$show" = "true" ] && detail=$(tr -d '[:space:]' < "$CFG/$path" 2>/dev/null)
      fi ;;
    env_value)
      # Value indicator (superset face from CLAUDE_SUPERSET_MODE: remote/local/
      # claude -> Rem/Loc/Cla), no on/off dot. Absent => nothing shown.
      _v="${!env:-}"
      if [ -n "$_v" ]; then
        _v3=$(printf '%s' "$_v" | cut -c1-3)
        detail="$(tr '[:lower:]' '[:upper:]' <<<"${_v3:0:1}")${_v3:1}"
        ansi="$ansi ${icon}\033[32m:${detail}\033[0m"
        plain="$plain ${label}:${detail}"
      fi
      continue ;;
  esac
  if [ "$on" = true ]; then
    ansi="$ansi ${icon}\033[32m●\033[0m"
    [ -n "$detail" ] && ansi="${ansi}\033[32m:${detail}\033[0m"
    plain="$plain ${label}:${detail:-on}"
  else
    ansi="$ansi ${icon}\033[90m○\033[0m"
    plain="$plain ${label}:off"
  fi
done <<EOF
$rows
EOF

ansi="${ansi# }"; plain="${plain# }"
if [ "$fmt" = "plain" ]; then
  printf '%s' "$plain"
else
  printf '%s' "PL[$ansi]"
fi
