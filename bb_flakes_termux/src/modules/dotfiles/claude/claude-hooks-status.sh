#!/usr/bin/env bash
# claude-hooks-status.sh — tier summary of the data-driven hook ruleset, for the
# statusline HK[…] segment (mirrors claude-plugins-status.sh PL[…]).
#
# Reads ~/.claude/hooks/hooks-rules.json — the SAME registry hook-engine.sh
# enforces — with ONE jq call. Spawn-free, safe on every render.
#
# Output (ansi):  HK[56 ⛔8 ⚠34 ✓7 ⊕7]
#   total · deny(red) · warn(yellow) · allow(green) · inject+nudge(grey)
#   plain:  Hooks:56 deny:8 warn:34 allow:7 ctx:7
#
# Missing registry / no jq → emits nothing (segment absent, like plugins).
# Present but unparseable → HK[✗] red, so a broken registry is visible.
#
# Usage: claude-hooks-status.sh [--format ansi|plain]
set -u

fmt="ansi"; [ "${1:-}" = "--format" ] && fmt="${2:-ansi}"
RULES="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/hooks-rules.json"

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$RULES" ] || exit 0

# One jq call → "total<TAB>deny<TAB>warn<TAB>allow<TAB>inject<TAB>nudge".
# ponytail: deny/warn/allow/inject/nudge is the rule schema's fixed severity
# enum; a new level would still land in `total`, add a glyph here when one does.
line=$(jq -r '
  (.rules // []) as $r |
  [ ($r|length)
  , ([$r[]|select(.level=="deny")]  |length)
  , ([$r[]|select(.level=="warn")]  |length)
  , ([$r[]|select(.level=="allow")] |length)
  , ([$r[]|select(.level=="inject")]|length)
  , ([$r[]|select(.level=="nudge")] |length)
  ] | @tsv' "$RULES" 2>/dev/null)

if [ -z "$line" ]; then
  [ "$fmt" = plain ] && printf 'Hooks:err' || printf 'HK[\033[31m✗\033[0m]'
  exit 0
fi

IFS=$'\t' read -r total deny warn allow inject nudge <<EOF
$line
EOF
ctx=$(( inject + nudge ))   # passive context tiers folded into one ⊕ bucket

if [ "$fmt" = plain ]; then
  printf 'Hooks:%s deny:%s warn:%s allow:%s ctx:%s' "$total" "$deny" "$warn" "$allow" "$ctx"
else
  # All counts green by default; red is reserved as an alert — only the deny
  # bucket turns red, and only when it actually carries blockers (deny>0).
  if [ "${deny:-0}" -gt 0 ]; then deny_color=31; else deny_color=32; fi
  printf 'HK[\033[32m%s\033[0m \033[%dm⛔%s\033[0m \033[32m⚠%s\033[0m \033[32m✓%s\033[0m \033[32m⊕%s\033[0m]' \
    "$total" "$deny_color" "$deny" "$warn" "$allow" "$ctx"
fi
