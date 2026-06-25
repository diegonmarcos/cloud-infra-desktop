#!/usr/bin/env bash
# ============================================================================
# gen-hooks-doc.sh — generate HOOKS.md from hooks-rules.json (single source).
# Deterministic (preserves array order) so a drift test can assert
# committed HOOKS.md == fresh output. Run from build.sh / manually:
#   bash gen-hooks-doc.sh > HOOKS.md
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RULES="${HOOK_RULES_FILE:-$HERE/hooks-rules.json}"
b64d() { printf '%s' "$1" | base64 -d 2>/dev/null; }

jq -e . "$RULES" >/dev/null || { echo "invalid hooks-rules.json" >&2; exit 1; }

emit_rows() { # $1=level — pattern/handler rules table
    jq -r --arg lvl "$1" '.rules[] | select(.level==$lvl)
        | (.id)+"\t"+(.category)+"\t"+(.event // "-")+"\t"
          +((.match.pattern // (if .handler then "handler:"+.handler else "-" end))|@base64)+"\t"
          +((.reason // "-")|@base64)+"\t"+((.alt // "")|@base64)' "$RULES" \
    | while IFS=$'\t' read -r id cat event pat_b reason_b alt_b; do
        pat="$(b64d "$pat_b")"; reason="$(b64d "$reason_b")"; alt="$(b64d "$alt_b")"
        printf '| `%s` | %s | %s | `%s` | %s | %s |\n' \
          "$id" "$cat" "$event" "$pat" "$reason" "${alt:-—}"
      done
}

cat <<'HDR'
# Claude Code Hooks — generated reference

> **GENERATED from `hooks-rules.json` by `gen-hooks-doc.sh` — do not hand-edit.**
> Edit the registry, then `build.sh switch` (a drift test asserts this file is current).

Two axes classify every rule:
- **Reinforcement level** — `allow` (tier-0 short-circuit) · `deny` (block, exit 2) ·
  `warn` (advisory, exit 0) · `nudge` (PostToolUse soft) · `inject` (context prose).
- **Purpose category** — `secrets` · `data-loss` · `declarative-bypass` · `vm-imperative` ·
  `shell-safety` · `arch-guessing` · `context`.

Enforcement is **PreToolUse:Bash only**; SessionStart/UserPromptSubmit are injection-only;
the nudge is PostToolUse. The guard is **fail-closed** (unreadable registry ⇒ deny).

HDR

echo "## Fires-on summary"
echo
echo "| level | count | event |"
echo "|---|---|---|"
for lvl in allow deny warn nudge inject; do
    n="$(jq -r --arg l "$lvl" '[.rules[]|select(.level==$l)]|length' "$RULES")"
    ev="$(jq -r --arg l "$lvl" '[.rules[]|select(.level==$l)|.event // (.tiers|join(","))]|unique|join(", ")' "$RULES")"
    printf '| %s | %s | %s |\n' "$lvl" "$n" "$ev"
done
echo

echo "## ALLOW — tier-0 short-circuit (read-only, silent)"
echo
echo "| id | category | event | pattern | reason | alt |"
echo "|---|---|---|---|---|---|"
emit_rows allow
echo

echo "## DENY — hard block (exit 2)"
echo
echo "| id | category | event | pattern / handler | reason | alt |"
echo "|---|---|---|---|---|---|"
emit_rows deny
echo

echo "## WARN — advisory (exit 0, first match wins)"
echo
echo "| id | category | event | pattern | reason | alt |"
echo "|---|---|---|---|---|---|"
emit_rows warn
echo

echo "## NUDGE — PostToolUse soft reminder"
echo
echo "| id | category | event | pattern / handler | reason | alt |"
echo "|---|---|---|---|---|---|"
emit_rows nudge
echo

echo "## INJECT — context prose by tier"
echo
echo "| id | category | fragment | tiers |"
echo "|---|---|---|---|"
jq -r '.rules[] | select(.level=="inject")
    | "| `"+.id+"` | "+.category+" | `"+.fragment+"` | "+(.tiers|join(", "))+" |"' "$RULES"
