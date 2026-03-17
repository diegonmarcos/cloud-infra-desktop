#!/usr/bin/env bash
# ============================================================================
# pretool-guard.sh — PreToolUse hook (mechanical command blocker)
#
# Fires BEFORE every Bash tool call. Extracts the command string from JSON
# stdin and pattern-matches against forbidden commands. Denies execution
# before the command ever reaches the shell.
#
# This is the LAST LINE OF DEFENSE — catches what even the smartest LLM
# ignores from pre-prompt instructions. Dumber models WILL ignore text
# rules; this hook enforces them mechanically.
#
# Source: ~/git/unix/bb_flakes_termux/src/modules/dotfiles/claude/
# Deployed to: ~/.claude/hooks/pretool-guard.sh (via home-manager)
#
# Input:  JSON on stdin { "tool_name": "Bash", "tool_input": { "command": "..." } }
# Output: JSON deny decision or nothing (allow)
# ============================================================================

set -euo pipefail

# Read stdin (tool call JSON)
INPUT=$(cat)

# Only act on Bash tool calls
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# Extract the command string
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -z "$CMD" ]; then
  exit 0
fi

# ── Helper: deny with reason ───────────────────────────────────────────────
deny() {
  local reason="$1"
  local alt="$2"
  cat <<EOF
{
  "hookSpecificOutput": {
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED by pretool-guard: ${reason}. USE INSTEAD: ${alt}. RULES: (a) FULLY DECLARATIVE nix-flakes-way — edit flakes in the git repo, never imperative commands. (b) IMPERATIVE SOLUTIONS FORBIDDEN — if something is broken, fix the universal engine (build.sh/_engine.sh), never bypass with workarounds. (c) BUILD/CI/CD ONLY through centralized engines — build.sh build, build.sh ship, or push to main for GHA auto-deploy."
  }
}
EOF
  exit 0
}

# ════════════════════════════════════════════════════════════════════════════
# TIER 0: ALWAYS ALLOW — read-only / introspection commands
# Skip all checks for safe commands that Claude Code needs internally
# ════════════════════════════════════════════════════════════════════════════

# npm read-only subcommands (Claude Code uses these internally)
if echo "$CMD" | grep -qE '^npm\s+(root|config|prefix|ls|list|ll|la|view|info|show|search|help|explain|doctor|audit|outdated|fund|pack|ping|whoami|token|profile|access|bugs|repo|completion|explore|-v|--version|-h|--help)(\s|$)'; then
  exit 0
fi

# nix read-only subcommands
if echo "$CMD" | grep -qE '^nix\s+(eval|show-derivation|path-info|log|why-depends|store|hash|doctor|registry|--version|--help|-h)(\s|$)'; then
  exit 0
fi
if echo "$CMD" | grep -qE '^nix\s+flake\s+(show|check|info|metadata)(\s|$)'; then
  exit 0
fi
if echo "$CMD" | grep -qE '^nix\s+profile\s+list(\s|$)'; then
  exit 0
fi

# docker read-only subcommands
if echo "$CMD" | grep -qE '^docker\s+(ps|images|logs|inspect|top|stats|diff|port|version|info|events|history|search|-v|--version|-h|--help)(\s|$)'; then
  exit 0
fi
if echo "$CMD" | grep -qE '^docker\s+(network|volume)\s+(ls|inspect)(\s|$)'; then
  exit 0
fi

# pip/pip3 read-only subcommands
if echo "$CMD" | grep -qE '^pip3?\s+(list|show|freeze|check|config|--version|-V|--help|-h)(\s|$)'; then
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
# BLOCKED — all denied commands. Every match calls deny() and stops.
# ════════════════════════════════════════════════════════════════════════════

# ── Destructive flag combos ──

if echo "$CMD" | grep -qiE 'docker\s+compose\s+down\s+.*(-v|--volumes)'; then
  deny "docker compose down -v wipes ALL Docker volumes (databases, state)" "build.sh compose"
fi

if echo "$CMD" | grep -qiE 'docker-compose\s+down\s+.*(-v|--volumes)'; then
  deny "docker-compose down -v wipes ALL Docker volumes" "build.sh compose"
fi

if echo "$CMD" | grep -qiE 'docker\s+volume\s+(rm|prune)'; then
  deny "docker volume rm/prune permanently deletes named volumes" "manual cleanup only after inspection"
fi

if echo "$CMD" | grep -qiE 'docker\s+system\s+prune\s+.*--volumes'; then
  deny "docker system prune --volumes removes everything including databases" "targeted cleanup only"
fi

if echo "$CMD" | grep -qiE 'rsync\s+.*--delete'; then
  deny "rsync --delete removes remote files not in source" "build.sh deploy"
fi

# ── Package managers: ALWAYS use build.sh deps/build ──

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*npm\s+install(\s|$)'; then
  deny "npm install bypasses declarative build system" "build.sh deps (or build.sh build)"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*npm\s+ci(\s|$)'; then
  deny "npm ci bypasses declarative build system" "build.sh deps"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*npm\s+run(\s|$)'; then
  deny "npm run bypasses declarative build system" "build.sh build (or build.sh dev)"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*npm\s+start(\s|$)'; then
  deny "npm start bypasses declarative build system" "build.sh dev"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*npm\s+test(\s|$)'; then
  deny "npm test bypasses declarative build system" "build.sh test"
fi

# npx — block ALL except --help/--version (whitelisted above)
if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*npx\s'; then
  deny "npx bypasses declarative build system" "build.sh build (esbuild/tsc/etc are run by the engine)"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*yarn(\s|$)'; then
  deny "yarn bypasses declarative build system" "build.sh deps/build"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*pnpm(\s|$)'; then
  deny "pnpm bypasses declarative build system" "build.sh deps/build"
fi

# ── Nix: ALWAYS use build.sh ──

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*nix-env\s'; then
  deny "nix-env -i is imperative package management" "add to flake.nix + build.sh switch"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*nix\s+build(\s|$)'; then
  deny "raw nix build bypasses the engine" "build.sh build"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*nix\s+run(\s|$)'; then
  deny "raw nix run bypasses the engine" "build.sh build"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*nixos-rebuild(\s|$)'; then
  deny "raw nixos-rebuild bypasses the engine" "build.sh switch"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*home-manager\s+(switch|build)(\s|$)'; then
  deny "raw home-manager switch/build bypasses the engine" "build.sh switch"
fi

# ── System package managers (not in this stack) ──

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*apt(-get)?\s+install(\s|$)'; then
  deny "apt install is imperative — Nix flake declarative only" "add to flake.nix"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*brew\s+install(\s|$)'; then
  deny "brew install is imperative" "add to flake.nix"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*pip3?\s+install(\s|$)'; then
  deny "pip install is imperative" "add to flake.nix or use nix-shell"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*conda\s+install(\s|$)'; then
  deny "conda install is imperative" "add to flake.nix"
fi

# ── Docker: ALWAYS use build.sh compose/ship ──

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*docker\s+compose\s+up(\s|$)'; then
  deny "docker compose up bypasses declarative deploy" "build.sh compose (or build.sh ship)"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*docker-compose\s+up(\s|$)'; then
  deny "docker-compose up bypasses declarative deploy" "build.sh compose"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*docker\s+compose\s+down(\s|$)'; then
  deny "docker compose down bypasses declarative deploy" "build.sh compose"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*docker\s+exec(\s|$)'; then
  deny "docker exec is imperative — never modify running containers" "docker logs for read-only inspection"
fi

# ── Shell antipatterns ──

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*which\s'; then
  deny "'which' doesn't exist on Termux/Nix" "command -v"
fi

if echo "$CMD" | grep -qE 'cd\s+[^\s;]+\s*&&\s*git\s+mv'; then
  deny "'cd dir && git mv' kills the shell if CWD is moved" "git -C /absolute/path mv ..."
fi

if echo "$CMD" | grep -qE 'cd\s+[^\s;]+\s*&&\s*rm\s+-rf'; then
  deny "'cd dir && rm -rf' kills the shell if CWD is deleted" "rm -rf /absolute/path (use absolute paths)"
fi

# ── SSH write operations (declarative only — SSH is READ-ONLY) ──

if echo "$CMD" | grep -qE 'ssh\s+\S+\s+.*\b(echo|sed|tee|cat)\s.*>'; then
  deny "SSH write operations are forbidden — declarative only" "edit source in git repo + build.sh ship"
fi

if echo "$CMD" | grep -qE 'ssh\s+\S+\s+.*\bsysctl\s+-w'; then
  deny "SSH sysctl -w is imperative" "add to nix config + build.sh ship"
fi

if echo "$CMD" | grep -qE 'ssh\s+\S+\s+.*\bdocker\s+exec'; then
  deny "docker exec on remote VMs is forbidden" "docker logs via SSH for read-only inspection"
fi

# ════════════════════════════════════════════════════════════════════════════
# DEFAULT: ALLOW — command passed all checks
# ════════════════════════════════════════════════════════════════════════════
exit 0
