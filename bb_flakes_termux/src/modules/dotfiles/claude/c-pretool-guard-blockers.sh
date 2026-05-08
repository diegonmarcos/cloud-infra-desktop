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

# ── 7A: imperative plaintext write into .secrets / .env bypasses sops ──
# Anchor to command boundary (^|;|&|||newline) so the verb must START a
# pipeline segment — prevents false-positives on quoted phrases inside
# commit messages, sed scripts, here-strings, etc.
if echo "$CMD" | grep -qE '(^|[;&|])\s*(echo|printf|tee)\b[^|;]*>>?\s*[^|;]*\.(secrets|env)\b'; then
    deny "imperative write to .secrets/.env bypasses sops" \
         "edit src/secrets.yaml + build.sh secrets"
fi

# ── 7B: git add of secret-shaped paths (.env/.key/.pem/.age/*secret*) ──
# Anchor on command boundary so `git add` must be the actual subcommand —
# `git commit -m "...git add..."` (literal phrase in message) won't trip.
# Carve-outs:
#   (a) inside ~/git/vault/  (private repo, sops-encrypted at rest)
#   (b) secrets.yaml that contains the sops marker (^sops: or ENC[AES256_GCM)
if echo "$CMD" | grep -qE '(^|[;&|])\s*git\s+(-[Cc]\s+\S+\s+)?add\b[^;|&]*(\.env|\.key|\.pem|\.age|secret)'; then
    case "$PWD" in "$HOME"/git/vault*) exit 0 ;; esac
    f=$(echo "$CMD" | grep -oE '\S+secrets\.ya?ml\b' | head -1 || true)
    if [ -n "$f" ] && [ -f "$f" ] && grep -qE '^sops:|ENC\[AES256_GCM' "$f" 2>/dev/null; then
        exit 0
    fi
    deny "git add of secret-shaped path — public-repo exposure risk" \
         "sops-encrypt secrets.yaml first; raw key material lives only in ~/git/vault"
fi

# Note: SSH write-redirect (ssh <host> '... echo/sed/tee/cat ... >') was
# previously a hard block. Demoted to advisory in c-pretool-guard-warning.sh
# 2026-05-07 — sometimes legitimate (one-shot debug, capturing remote output
# locally), so warn-only is the right tier.

# ── Default: allow (no blocker pattern matched) ──
exit 0
