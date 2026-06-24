#!/usr/bin/env bash
# ============================================================================
# c-posttool-graph-nudge.sh — TIER C: PostToolUse soft nudge (FIRE rule 6)
#
# Fires AFTER every tool call. Counts consecutive Read/Grep/Glob calls that
# happen WITHOUT any cloud-cgc-mcp query. Once the count hits THRESHOLD, it
# injects a non-blocking reminder (hookSpecificOutput.additionalContext) to
# use octocode_graphrag/search instead of read-5-files-and-guess-the-6th.
# Any cloud-cgc-mcp call resets the counter.
#
# This is the ONLY way to "enforce" the no-guessing rule: guessing isn't a
# shell-command pattern, so PreToolUse:Bash blockers can't catch it. This is a
# soft PostToolUse nudge, never a deny — it ALWAYS exits 0.
#
# Input:  JSON on stdin { tool_name, session_id, ... }
# Output: optional JSON { hookSpecificOutput: { additionalContext } }, exit 0
#
# ponytail: THRESHOLD hardcoded at 5 — move to hooks-rules.json in the
# data-driven refactor. Counter is per-session (keyed on session_id), not
# per-turn; good enough for a nudge. Upgrade to per-turn reset (via a
# UserPromptSubmit hook) only if it over- or under-fires in practice.
# ============================================================================
set -uo pipefail

THRESHOLD=5

INPUT=$(cat 2>/dev/null || true)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"' 2>/dev/null || true)
[ -n "$TOOL" ] || exit 0

STATE="${TMPDIR:-/tmp}/claude-graph-nudge-${SID}"

# A cloud-cgc-mcp query satisfies the rule → reset the counter, stay silent.
case "$TOOL" in
  mcp__cloud-cgc*) printf '0' > "$STATE" 2>/dev/null || true; exit 0 ;;
esac

# Only file-exploration tools count toward the nudge.
case "$TOOL" in
  Read|Grep|Glob) ;;
  *) exit 0 ;;
esac

count=0
[ -f "$STATE" ] && count=$(cat "$STATE" 2>/dev/null || echo 0)
case "$count" in ''|*[!0-9]*) count=0 ;; esac
count=$((count + 1))

if [ "$count" -ge "$THRESHOLD" ]; then
    printf '0' > "$STATE" 2>/dev/null || true
    jq -nc --arg ctx "REMINDER (FIRE rule 6): ${THRESHOLD} file reads/searches with no cloud-cgc-mcp query. Before reasoning about architecture, use octocode_graphrag / octocode_search / knowledge_* / c3_* — don't read-5-files-and-guess-the-6th." '{
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: $ctx
        }
    }' 2>/dev/null || true
else
    printf '%s' "$count" > "$STATE" 2>/dev/null || true
fi

exit 0
