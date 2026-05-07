#!/usr/bin/env bash
# ============================================================================
# c-pretool-guard-blockers.sh — TIER C: PreToolUse(Bash) HARD BLOCKERS
#
# Fires BEFORE every Bash tool call. Inspects the command and EXIT 2's on
# patterns that have NO legitimate use in this declarative stack — making
# the tool call deny outright. stderr message goes to the model so it can
# adjust strategy.
#
# Companion script: c-pretool-guard-warning.sh (same matcher, advisory tier).
# Order in settings.json: blockers FIRST, warnings SECOND.
#
# Source: ~/git/unix/{ba_flakes_desktop,bb_flakes_termux}/src/modules/dotfiles/claude/
# Deployed: ~/.claude/hooks/c-pretool-guard-blockers.sh (via home-manager)
#
# Input:  JSON on stdin { "tool_name": "Bash", "tool_input": { "command": "..." } }
# Output: deny reason on stderr, exit 2 → tool call denied + model sees stderr
# ============================================================================

set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$TOOL_NAME" = "Bash" ] || exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$CMD" ] || exit 0

# ── Helper: hard-deny the tool call ────────────────────────────────────────
# exit 2 → Claude Code blocks the tool call and forwards stderr to the model.
deny() {
    local reason="$1"
    local alt="$2"
    echo "🛑 BLOCKED by c-pretool-guard-blockers.sh: ${reason}" >&2
    echo "   Use instead: ${alt}" >&2
    exit 2
}

# ════════════════════════════════════════════════════════════════════════════
# DENY LIST — patterns with NO legitimate use in this declarative stack
# ════════════════════════════════════════════════════════════════════════════

# ── Secret-leak vector: git add -f / --force bypasses gitignore ──
if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*git\s+(-[Cc]\s+\S+\s+)?add\s+(-f\b|--force\b)'; then
    deny "git add -f/--force bypasses gitignore — can stage decrypted secrets, private keys, sensitive/" \
         "plain 'git add <path>'; if gitignore blocks a file, FIX gitignore — never force"
fi

# ── Volume wipe: docker compose down -v / --volumes ──
if echo "$CMD" | grep -qiE 'docker(-compose|\s+compose)\s+down\s+.*(-v\b|--volumes\b)'; then
    deny "docker compose down -v wipes ALL named volumes (databases, state) — irreversible" \
         "docker compose down (without -v) or build.sh compose"
fi

# ── Volume rm/prune: irreversible per-volume deletion ──
if echo "$CMD" | grep -qiE 'docker\s+volume\s+(rm|prune)\b'; then
    deny "docker volume rm/prune permanently deletes named volumes — irreversible" \
         "manual cleanup only after explicit user confirmation; inspect with 'docker volume ls' first"
fi

# ── docker system prune --volumes: same blast radius as volume prune ──
if echo "$CMD" | grep -qiE 'docker\s+system\s+prune\s+.*--volumes\b'; then
    deny "docker system prune --volumes wipes everything including databases" \
         "targeted cleanup; inspect with 'docker system df' first"
fi

# ── nix-env -i / -iA: imperative install pollutes user profile ──
if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*nix-env\s+(-i|--install|-iA)\b'; then
    deny "nix-env -i is imperative package management — pollutes the user profile and breaks declarative reproducibility" \
         "add the package to flake.nix (home.packages or environment.systemPackages) + build.sh switch"
fi

# ── SSH write-redirect: contradicts declarative stack ──
# Pattern matches: ssh <host> "...echo/sed/tee/cat ... >..."
# (Catches both `>` and `>>` write redirects executed remotely.)
if echo "$CMD" | grep -qE 'ssh\s+\S+\s+.*\b(echo|sed|tee|cat|printf)\s.*>>?'; then
    deny "SSH write-redirect contradicts declarative stack — VMs are read-only at runtime" \
         "edit source in git repo (src/) + build.sh ship — config drifts only via the build pipeline"
fi

# ── Default: allow (no blocker pattern matched) ──
exit 0
