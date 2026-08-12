#!/usr/bin/env bash
# deepseek-cleanup.sh — one-time removal of the 2026-08 deepseek debugging
# leftovers. Idempotent, safe to re-run. Full xtrace → ~/deepseek-cleanup.log.
#
# What it removes (evidence: claude-fix.log, 2026-08-08 session):
#   ~/.local/bin/claude.bin         294MB copy of the native claude binary
#   ~/.local/bin/claude-tty         symlink → ~/claude-tty
#   ~/claude-tty                    debug wrapper that piped stdin (the --print bug)
#   ~/.claude/claude-tty-debug.log  probe log
#   files/usr/lib/node_modules/@anthropic-ai/claude-code
#   files/usr/bin/claude            pre-nix npm install in the plain-Termux prefix
#
# NOT touched: claude-malloc / claude-termux / claude-rescue / claude-orphan-sweep
# / claude-superset* — those are the legit wrappers.
#
# Gate: refuses to run unless the real nix claude answers --version first.
set -u

# ONE output convention — see 1_cicd/src/scripts/cloud-data-paths.sh
CDP="$HOME/git/unix/1_cicd/dist/scripts/cloud-data-paths.sh"
if [ -r "$CDP" ]; then . "$CDP"; LOG="$(cd_log deepseek-cleanup)"; else LOG="$HOME/deepseek-cleanup.log"; fi
REAL="$HOME/.nix-profile/bin/claude"
TERMUX_PREFIX="/data/data/com.termux.nix/files/usr"

# APPEND, never truncate — the log holds the only copy of deleted wrapper
# scripts, and a later re-run must not destroy it.
touch "$LOG"
exec 3>>"$LOG"
export BASH_XTRACEFD=3
PS4='+ [$(date "+%H:%M:%S")] line ${LINENO}: '
set -x

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

say "══════ deepseek-cleanup $(date -u +%Y-%m-%dT%H:%M:%SZ) ══════"
if ! timeout 30 "$REAL" --version >/dev/null 2>&1; then
  say "ABORT: $REAL not working — fix claude first (bash ~/claude-fix.sh), then re-run."
  exit 1
fi
say "gate OK: nix claude answers ($("$REAL" --version 2>/dev/null))"
say ""

freed=0
zap() { # zap <path> <description>
  local p=$1 desc=$2 sz
  # identity guard: linkNixBinsToTermux recreates files/usr/bin/claude as a
  # SYMLINK TO THE REAL BINARY after every switch — deleting it would undo
  # that on every run (2026-08-08 audit).
  if [ "$(readlink -f "$p" 2>/dev/null)" = "$(readlink -f "$REAL" 2>/dev/null)" ]; then
    say "kept (is the real claude): $p"
    return 0
  fi
  if [ -e "$p" ] || [ -L "$p" ]; then
    sz=$(du -sk "$p" 2>/dev/null | cut -f1)
    : "${sz:=0}"
    # Preserve small text artifacts (the wrapper scripts) in the log before
    # deletion — the 294MB binary blob is just a copy, nothing to keep.
    if [ -f "$p" ] && [ "$sz" -lt 64 ]; then
      { echo "----- content of $p (pre-deletion) -----"; cat "$p"; echo "----- end -----"; } >>"$LOG" 2>/dev/null
    fi
    if rm -rf "$p"; then
      freed=$((freed + sz))
      say "removed      : $p  ($desc, ${sz}KB)"
    else
      say "FAILED to rm : $p  ($desc)"
    fi
  else
    say "already gone : $p  ($desc)"
  fi
}

zap "$HOME/.local/bin/claude.bin"        "binary copy"
zap "$HOME/.local/bin/claude-tty"        "symlink to debug wrapper"
zap "$HOME/claude-tty"                   "debug wrapper — caused the --print stdin bug"
zap "$HOME/.claude/claude-tty-debug.log" "probe log"
zap "$TERMUX_PREFIX/lib/node_modules/@anthropic-ai/claude-code" "pre-nix npm install"
zap "$TERMUX_PREFIX/bin/claude"          "npm shim of the pre-nix install"

say ""
say "freed ~$((freed / 1024)) MB · full log: $LOG"
say "verify: type -a claude   → only .nix-profile entries should remain"
