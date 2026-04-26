#!/usr/bin/env bash
# ============================================================================
# declarative-guard.sh — UserPromptSubmit hook (L4: per-prompt reinforcement)
#
# Fires on EVERY prompt. Injects a short declarative-only reminder so the
# agent never drifts into imperative solutions mid-conversation.
#
# Source: ~/git/unix/ba_flakes_desktop/src/modules/dotfiles/claude/
# Deployed to: ~/.claude/hooks/declarative-guard.sh (via home-manager)
# ============================================================================

cat <<'GUARD'
## FIRE RULES (non-negotiable)
1. NO INLINE COMMANDS FULL OF ARGS. NO HACKS EVER. Always fix the engine (`build.sh` / `_engine.sh` / flake) — never bypass it with a one-liner.
2. **INTERVAL CONFIDENCE LEVEL**: By default the model MUST answer at 97.5% confidence. ≤ 2.5% may be extrapolation; ≥ 97.5% MUST be sourced from EVIDENCE (file reads, command output, MCP tool results, fetched docs). NEVER answer with 0 evidences fetched — if no evidence has been gathered yet, fetch it first.
3. NO IMPERATIVE SOLUTION if it is not already DECLARED. An "easy fix" is not a fix — it is a new potential BUG. Declarative always.
4. DATA-DRIVEN ONLY. Never hardcode data in scripts. Use `build.json` or auxiliary `.json` files (cloud-data-*.json, config.json, etc.) as the source of truth.
5. A TASK IS NOT DONE UNTIL IT HAS A TESTER. After every solution, design the test that proves it — no task is complete without a test.

## Stack Philosophy
0. IMPERATIVE SOLUTIONS ARE FORBIDDEN
1. FULLY DECLARATIVE ENVIRONMENT
2. BUILD AND CI/CD ONLY DONE BY UNIVERSAL ENGINES
3. MCP TOOLS USE IS MANDATORY
4. WHEN DETECTED A BUG IN AN ENGINE THE ISSUE MUST BE FIXED IMMEDIATELY NOT BE BYPASSED BY TEMPORARY WORKAROUNDS EVER!

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

## DEAD SHELL RECOVERY

If Bash fails on everything (even `echo test`), the CWD was deleted by git mv/rm.
**Fix**: Use `Write` tool to create a dummy file at the dead path → restores CWD → Bash works again.
Then clean up with `git checkout HEAD -- path/` or continue with absolute paths.
GUARD
