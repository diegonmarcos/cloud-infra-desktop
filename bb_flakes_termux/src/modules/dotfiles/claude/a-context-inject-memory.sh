#!/usr/bin/env bash
# ============================================================================
# a-context-inject-memory.sh — TIER A: SessionStart context injector
#
# Fires once per Claude Code session. Emits the mandatory pre-action checklist
# + forbidden-pattern table to stdout — Claude Code captures it as
# additionalContext, persisting in the conversation prompt for the whole
# session.
#
# Source: ~/git/unix/{ba_flakes_desktop,bb_flakes_termux}/src/modules/dotfiles/claude/
# Deployed: ~/.claude/hooks/a-context-inject-memory.sh (via home-manager)
# Wired in: settings.json → hooks.SessionStart[0].hooks[0].command
#
# Tier model:
#   a) SessionStart       → CLAUDE.md + a-context-inject-memory.sh
#   b) UserPromptSubmit   → b-context-inject-prompt.sh
#   c) PreToolUse(Bash)   → c-pretool-guard-blockers.sh (deny patterns)
#                         + c-pretool-guard-warning.sh (advisory patterns)
# ============================================================================

cat <<'CHECKLIST'
## MANDATORY PRE-ACTION CHECKLIST

Before EVERY modification:
1. **SOURCE CHECK**: Am I editing SOURCE (git `src/`) or DEPLOYED output (VM, dist/, ~/.claude/)?
2. **PIPELINE CHECK**: Am I using `build.sh` or bypassing it?
3. **SECRETS CHECK**: Am I creating secrets via sops pipeline or manually?
4. **SHELL CHECK**: `command -v` not `which`. Nix source not `sed` on VM.

## FORBIDDEN PATTERNS

| NEVER | ALWAYS |
|-------|--------|
| `ssh vm 'echo > .secrets'` | `src/secrets.yaml` + sops + `build.sh ship` |
| `nix-env -i pkg` | Add to flake + rebuild |
| `sed` on VM `/etc/` files | Edit nix source + deploy |
| `docker compose up` on VM | `build.sh compose` |
| `which cmd` | `command -v cmd` |
| Edit `dist/` files | Edit `src/` + `build.sh build` |
| Edit `~/.claude/CLAUDE.md` | Edit source in `~/git/unix/` flakes |
| `cd dir && git mv dir/...` | `git -C /abs/path mv ...` (absolute paths) |
| `git add -f` / `git add --force` | plain `git add` — NEVER bypass gitignore. `-f` force-stages secrets, decrypted keys, sensitive/ — gitignore exists for a reason. |
CHECKLIST
