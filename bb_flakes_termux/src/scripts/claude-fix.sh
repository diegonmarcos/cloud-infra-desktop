#!/usr/bin/env bash
# claude-fix.sh — diagnose & repair a shadowed / non-starting `claude` on this phone.
#
# Deployed to ~/claude-fix.sh by flake.nix (home.file). Run it plain:
#   bash ~/claude-fix.sh
#
# Workflow (the 2026-08-08 debugging session, automated):
#   1/5  Record environment + how `claude` resolves (bash AND fish view)
#   2/5  Detect shadows — anything named `claude` resolving BEFORE the real
#        nix binary ($HOME/.nix-profile/bin/claude): stale npm shims in
#        ~/.node_modules/node_modules/.bin, leftover debug wrappers
#        (claude-tty experiments) in ~/.local/bin, persisted fish functions
#   3/5  Back every shadow up to ~/claude-fix-backup.<ts>/ then remove it
#   4/5  Verify the real binary runs (--version)
#   5/5  Timed end-to-end startup probe (-p) with its own --debug-file,
#        plus `claude mcp list` health
#
# ALL output — including full bash xtrace of every command this script runs —
# goes to ~/claude-fix.log. Console shows the human-readable subset.
set -u
# pipefail: run()/probes pipe through tee — without it the pipeline exit
# is TEE's (always 0) and every verification prints OK even when claude is
# dead (2026-08-08 audit).
set -o pipefail

# ONE output convention — see 1_workflows/src/scripts/cloud-data-paths.sh
CDP="$HOME/git/unix/1_workflows/dist/scripts/cloud-data-paths.sh"
if [ -r "$CDP" ]; then . "$CDP"; LOG="$(cd_log claude-fix)"; else LOG="$HOME/claude-fix.log"; fi
STARTUP_DEBUG="${LOG%.log}-startup-debug.log"
REAL="$HOME/.nix-profile/bin/claude"
BACKUP_DIR="$HOME/claude-fix-backup.$(date +%Y%m%d-%H%M%S)"

: > "$LOG"
# fd3 = the log; xtrace goes there so the console stays readable while the
# log captures every command + timestamp.
exec 3>>"$LOG"
export BASH_XTRACEFD=3
PS4='+ [$(date "+%H:%M:%S")] line ${LINENO}: '
set -x

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
hdr() { say ""; say "══════ $* ══════"; }
run() { say "\$ $*"; "$@" 2>&1 | tee -a "$LOG"; }

fail=0

hdr "claude-fix $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "log: $LOG"

# ── 1/5 environment ─────────────────────────────────────────────────────
hdr "1/5 environment"
run uname -a
say "PATH=$PATH"
say ""
say "bash resolution of 'claude' (first hit wins):"
run bash -c 'type -a claude || echo "  (not found in bash PATH)"'
if command -v fish >/dev/null 2>&1; then
  say "fish resolution of 'claude':"
  fish -c 'type -a claude' 2>&1 | tee -a "$LOG" || say "  (not found in fish)"
  say "fish abbr/alias mentioning claude (informational):"
  fish -c 'abbr --show' 2>/dev/null | grep -i claude | tee -a "$LOG" || say "  (none)"
fi

# ── 2/5 shadow detection ───────────────────────────────────────────────
hdr "2/5 shadow detection"
# SAFETY GATE: if the real nix binary is missing, DO NOT classify anything
# as a shadow — with no reference, every claude on PATH would look removable
# (including legitimate system copies). Diagnose-only in that case.
if [ ! -x "$REAL" ]; then
  say "FAIL: $REAL missing — refusing to remove anything without a reference binary."
  say "run: cd ~/git/unix/bb_flakes_termux && ./build.sh switch   then re-run this script"
  say "full debug log: $LOG"
  exit 1
fi
real_id="$(readlink -f "$REAL" 2>/dev/null || echo "$REAL")"
shadows=()
# Everything named `claude` on PATH, in resolution order. Only entries under
# $HOME are removal candidates — a shadow in a system dir (/opt, /usr, /nix)
# means the PATH ORDER is wrong, not that the file should die.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  p_id="$(readlink -f "$p" 2>/dev/null || echo "$p")"
  if [ "$p_id" = "$real_id" ]; then
    say "  ok   $p (the real nix binary)"
  else
    case "$p" in
      "$HOME"/*)
        say "  BAD  $p (shadows the real binary — will remove)"
        shadows+=("$p") ;;
      *)
        say "  WARN $p (shadows the real binary but is OUTSIDE \$HOME — not touching; fix PATH order)" ;;
    esac
  fi
done < <(type -aP claude 2>/dev/null)
# …plus the two known writable dirs even if not currently first in PATH.
for p in "$HOME/.node_modules/node_modules/.bin/claude" "$HOME/.local/bin/claude"; do
  [ -e "$p" ] || [ -L "$p" ] || continue
  p_id="$(readlink -f "$p" 2>/dev/null || echo "$p")"
  if [ "$p_id" != "$real_id" ]; then
    case " ${shadows[*]-} " in *" $p "*) ;; *)
      say "  BAD  $p (stale shim, not on active PATH resolution but present)"
      shadows+=("$p") ;;
    esac
  fi
done
# Leftover debug-harness scripts — logged, never auto-deleted (only exact-name
# `claude` shadows get removed; claude-malloc/-termux/-rescue are legit).
say "other claude* entries in writable bins (informational):"
ls -la "$HOME/.local/bin"/claude* "$HOME/.node_modules/node_modules/.bin"/claude* 2>/dev/null | tee -a "$LOG" || say "  (none)"

# fish function shadow — beats PATH entirely.
fish_fn=0
if command -v fish >/dev/null 2>&1 && fish -c 'functions -q claude' 2>/dev/null; then
  fish_fn=1
  say "  BAD  fish function 'claude' exists — body:"
  fish -c 'functions claude' 2>&1 | tee -a "$LOG"
fi

# ── 3/5 remove shadows (with backup) ───────────────────────────────────
hdr "3/5 remove shadows"
if [ "${#shadows[@]}" -eq 0 ] && [ "$fish_fn" -eq 0 ]; then
  say "no shadows found — nothing to remove."
else
  mkdir -p "$BACKUP_DIR"
  for p in ${shadows[@]+"${shadows[@]}"}; do
    cp -a "$p" "$BACKUP_DIR/" 2>>"$LOG" || true
    rm -f "$p" && say "removed: $p  (backup in $BACKUP_DIR)"
  done
  if [ "$fish_fn" -eq 1 ]; then
    fish -c 'functions claude' > "$BACKUP_DIR/claude.fish-function" 2>/dev/null || true
    fish -c 'functions --erase claude' 2>>"$LOG" || true
    rm -f "$HOME/.config/fish/functions/claude.fish"
    say "erased fish function 'claude'  (backup in $BACKUP_DIR/claude.fish-function)"
  fi
fi

# ── 4/5 verify real binary ─────────────────────────────────────────────
hdr "4/5 verify real binary"
if [ ! -x "$REAL" ]; then
  say "FAIL: $REAL missing or not executable — run: cd ~/git/unix/bb_flakes_termux && ./build.sh switch"
  fail=1
else
  if run timeout 30 "$REAL" --version; then
    say "OK: --version works"
  else
    say "FAIL: --version errored/timed out (see $LOG)"
    fail=1
  fi
fi

# ── 5/5 timed startup probe ────────────────────────────────────────────
hdr "5/5 timed startup probe"
if [ "$fail" -eq 0 ]; then
  say "running: claude -p (120s cap, debug → $STARTUP_DEBUG)"
  t0=$(date +%s)
  if timeout 120 "$REAL" --debug-file "$STARTUP_DEBUG" -p 'reply with exactly: ok' </dev/null 2>&1 | tee -a "$LOG"; then
    say "OK: end-to-end probe succeeded in $(( $(date +%s) - t0 ))s"
  else
    say "FAIL: probe errored/timed out after $(( $(date +%s) - t0 ))s — read $STARTUP_DEBUG for the stall point (MCP connects log there)"
    fail=1
  fi
  say ""
  say "MCP server health:"
  timeout 90 "$REAL" mcp list 2>&1 | tee -a "$LOG" || say "  (mcp list errored/timed out)"
else
  say "skipped — binary verification failed."
fi

# ── summary ────────────────────────────────────────────────────────────
hdr "summary"
say "shadows removed : ${#shadows[@]} file(s), fish function: $fish_fn"
[ -d "$BACKUP_DIR" ] && say "backups         : $BACKUP_DIR"
say "full debug log  : $LOG"
say "startup debug   : $STARTUP_DEBUG (from the -p probe)"
say "now run 'hash -r' (bash) or open a NEW shell, then plain: claude"
exit "$fail"
