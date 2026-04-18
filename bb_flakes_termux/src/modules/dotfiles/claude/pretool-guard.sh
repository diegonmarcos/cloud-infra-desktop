#!/usr/bin/env bash
# ============================================================================
# pretool-guard.sh — PreToolUse hook (WARN-ONLY advisory)
#
# Fires BEFORE every Bash tool call. Extracts the command string from JSON
# stdin and pattern-matches against discouraged commands. Emits a WARNING
# to stderr but NEVER blocks execution (always exits 0).
#
# Source: ~/git/unix/{ba_flakes_desktop,bb_flakes_termux}/src/modules/dotfiles/claude/
# Deployed to: ~/.claude/hooks/pretool-guard.sh (via home-manager)
#
# Input:  JSON on stdin { "tool_name": "Bash", "tool_input": { "command": "..." } }
# Output: warning text on stderr, exit 0 (never denies, never asks)
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

# ── Helper: warn with reason (non-blocking) ────────────────────────────────
# Emits warning to stderr and exits 0 so Claude proceeds. Never blocks,
# never asks for confirmation — user just sees the advisory in the transcript.
warn() {
  local reason="$1"
  local alt="$2"
  echo "⚠️  pretool-guard WARNING (non-blocking): ${reason}. Better: ${alt}" >&2
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
# ADVISORY — every match calls warn() (stderr + exit 0). Never blocks.
# ════════════════════════════════════════════════════════════════════════════

# ── Destructive flag combos ──

if echo "$CMD" | grep -qiE 'docker\s+compose\s+down\s+.*(-v|--volumes)'; then
  warn "docker compose down -v wipes ALL Docker volumes (databases, state)" "build.sh compose"
fi

if echo "$CMD" | grep -qiE 'docker-compose\s+down\s+.*(-v|--volumes)'; then
  warn "docker-compose down -v wipes ALL Docker volumes" "build.sh compose"
fi

if echo "$CMD" | grep -qiE 'docker\s+volume\s+(rm|prune)'; then
  warn "docker volume rm/prune permanently deletes named volumes" "manual cleanup only after inspection"
fi

if echo "$CMD" | grep -qiE 'docker\s+system\s+prune\s+.*--volumes'; then
  warn "docker system prune --volumes removes everything including databases" "targeted cleanup only"
fi

if echo "$CMD" | grep -qiE 'rsync\s+.*--delete'; then
  warn "rsync --delete removes remote files not in source" "build.sh deploy"
fi

# ── Package managers: ALWAYS use build.sh deps/build ──

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*npm\s+install(\s|$)'; then
  warn "npm install bypasses declarative build system" "build.sh deps (or build.sh build)"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*npm\s+ci(\s|$)'; then
  warn "npm ci bypasses declarative build system" "build.sh deps"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*npm\s+run(\s|$)'; then
  warn "npm run bypasses declarative build system" "build.sh build (or build.sh dev)"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*npm\s+start(\s|$)'; then
  warn "npm start bypasses declarative build system" "build.sh dev"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*npm\s+test(\s|$)'; then
  warn "npm test bypasses declarative build system" "build.sh test"
fi

# npx — block ALL except --help/--version (whitelisted above)
if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*npx\s'; then
  warn "npx bypasses declarative build system" "build.sh build (esbuild/tsc/etc are run by the engine)"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*yarn(\s|$)'; then
  warn "yarn bypasses declarative build system" "build.sh deps/build"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*pnpm(\s|$)'; then
  warn "pnpm bypasses declarative build system" "build.sh deps/build"
fi

# ── Nix: ALWAYS use build.sh ──

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*nix-env\s'; then
  warn "nix-env -i is imperative package management" "add to flake.nix + build.sh switch"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*nix\s+build(\s|$)'; then
  warn "raw nix build bypasses the engine" "build.sh build"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*nix\s+run(\s|$)'; then
  warn "raw nix run bypasses the engine" "build.sh build"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*nixos-rebuild(\s|$)'; then
  warn "raw nixos-rebuild bypasses the engine" "build.sh switch"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*home-manager\s+(switch|build)(\s|$)'; then
  warn "raw home-manager switch/build bypasses the engine" "build.sh switch"
fi

# ── System package managers (not in this stack) ──

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*apt(-get)?\s+install(\s|$)'; then
  warn "apt install is imperative — Nix flake declarative only" "add to flake.nix"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*brew\s+install(\s|$)'; then
  warn "brew install is imperative" "add to flake.nix"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*pip3?\s+install(\s|$)'; then
  warn "pip install is imperative" "add to flake.nix or use nix-shell"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*conda\s+install(\s|$)'; then
  warn "conda install is imperative" "add to flake.nix"
fi

# ── Docker: ALWAYS use build.sh compose/ship ──

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*docker\s+compose\s+up(\s|$)'; then
  warn "docker compose up bypasses declarative deploy" "build.sh compose (or build.sh ship)"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*docker-compose\s+up(\s|$)'; then
  warn "docker-compose up bypasses declarative deploy" "build.sh compose"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*docker\s+compose\s+down(\s|$)'; then
  warn "docker compose down bypasses declarative deploy" "build.sh compose"
fi

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*docker\s+exec(\s|$)'; then
  warn "docker exec is imperative — never modify running containers" "docker logs for read-only inspection"
fi

# ── Shell antipatterns ──

if echo "$CMD" | grep -qE '(^|\s|;|&&|\|)\s*which\s'; then
  warn "'which' doesn't exist on Termux/Nix" "command -v"
fi

if echo "$CMD" | grep -qE 'cd\s+[^\s;]+\s*&&\s*git\s+mv'; then
  warn "'cd dir && git mv' kills the shell if CWD is moved" "git -C /absolute/path mv ..."
fi

if echo "$CMD" | grep -qE 'cd\s+[^\s;]+\s*&&\s*rm\s+-rf'; then
  warn "'cd dir && rm -rf' kills the shell if CWD is deleted" "rm -rf /absolute/path (use absolute paths)"
fi

# ── SSH write operations (declarative only — SSH is READ-ONLY) ──

if echo "$CMD" | grep -qE 'ssh\s+\S+\s+.*\b(echo|sed|tee|cat)\s.*>'; then
  warn "SSH write operations are forbidden — declarative only" "edit source in git repo + build.sh ship"
fi

if echo "$CMD" | grep -qE 'ssh\s+\S+\s+.*\bsysctl\s+-w'; then
  warn "SSH sysctl -w is imperative" "add to nix config + build.sh ship"
fi

if echo "$CMD" | grep -qE 'ssh\s+\S+\s+.*\bdocker\s+exec'; then
  warn "docker exec on remote VMs is forbidden" "docker logs via SSH for read-only inspection"
fi

# ════════════════════════════════════════════════════════════════════════════
# DEFAULT: ALLOW — command passed all checks
# ════════════════════════════════════════════════════════════════════════════
exit 0
