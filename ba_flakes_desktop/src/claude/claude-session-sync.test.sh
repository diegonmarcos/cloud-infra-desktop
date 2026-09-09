#!/usr/bin/env bash
# ============================================================================
# claude-session-sync.test.sh — the transcript archive's wiring, on surface
# ----------------------------------------------------------------------------
# The bug this guards: ~/.claude/projects is a symlink into
# cloud-data-my-ai-memory, so every Claude Code transcript is written straight
# into a git worktree — and until 2026-09-09 nothing ever committed it. The ten
# commits in that repo were made by hand, with gaps of one, six and thirteen
# days, and the symlink that makes the whole arrangement work was not declared
# anywhere: a rebuilt machine would have got a plain directory, written its
# transcripts outside the repo, and shown no error at all.
#
# Static assertions only — this repo cannot build or evaluate a flake (no nix on
# the agent host, wrong platform for the desktop closure), so these are the
# checks that are worth more than nothing rather than a substitute for a switch.
# What they cover is the class of mistake a careless edit reintroduces:
#   1. the state symlinks are declared, and BEFORE the links that live inside
#      them (order is load-bearing — see the comment in claude.nix),
#   2. the pre-commit hook path is asserted, and cannot kill an interactive
#      home-manager switch when it fails,
#   3. the timer exists, catches up missed runs, and points at the archive's own
#      script instead of reimplementing it,
#   4. no size threshold has been copied into nix. The numbers live in the
#      memory repo's bin/session-limits.json and must stay there.
# ============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_NIX="$DIR/claude.nix"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
nope() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "▶ claude-session-sync.test.sh — transcript archive wiring (surface)"
[ -f "$CLAUDE_NIX" ] || { nope "claude.nix missing at $CLAUDE_NIX"; exit 1; }

# ── 1 · the state directories are declared, in the order that works ─────────
echo "▶ Phase 1 · state symlinks"
for d in projects file-history shell-snapshots; do
  grep -q "a_sessions/\$INSTANCE/$d\"" "$CLAUDE_NIX" \
    && ok "~/.claude/$d is declared" \
    || nope "~/.claude/$d is NOT declared — a rebuilt machine writes it outside the archive"
done

proj_line=$(grep -n 'a_sessions/\$INSTANCE/projects"' "$CLAUDE_NIX" | head -1 | cut -d: -f1)
mem_line=$(grep -n 'b_projects/home-diego/MEMORY.md"' "$CLAUDE_NIX" | head -1 | cut -d: -f1)
if [ -n "$proj_line" ] && [ -n "$mem_line" ] && [ "$proj_line" -lt "$mem_line" ]; then
  ok "projects is linked before the links that live inside it (line $proj_line < $mem_line)"
else
  nope "MEMORY.md is linked before projects — the mkdir would make projects a real dir and the projects link would then be moved aside"
fi

# ── 2 · the pre-commit hook is armed, and cannot break a switch ─────────────
echo "▶ Phase 2 · core.hooksPath"
grep -q 'config core.hooksPath bin/hooks' "$CLAUDE_NIX" \
  && ok "core.hooksPath is asserted on every switch" \
  || nope "core.hooksPath is not set — a fresh clone commits oversized blobs unchecked"

# home-manager runs activation under `set -e` and this block has no subshell
# wrapper, so an unguarded git failure takes the whole switch down.
grep -A3 'config core.hooksPath bin/hooks' "$CLAUDE_NIX" | grep -q '|| echo' \
  && ok "the git call degrades to a warning instead of aborting the switch" \
  || nope "the git call is unguarded — a failure here kills an interactive home-manager switch"

# ── 3 · the timer ───────────────────────────────────────────────────────────
echo "▶ Phase 3 · systemd user timer"
grep -q 'systemd.user.timers.claude-session-sync' "$CLAUDE_NIX" \
  && ok "timer declared" || nope "no timer — the archive is manual again"
grep -q 'systemd.user.services.claude-session-sync' "$CLAUDE_NIX" \
  && ok "service declared" || nope "no service for the timer to trigger"
grep -A6 'systemd.user.timers.claude-session-sync' "$CLAUDE_NIX" | grep -q 'OnCalendar = "hourly"' \
  && ok "fires hourly (28x margin on the ~28h shard-threshold-to-blob-limit window)" \
  || nope "not hourly — a daily cadence leaves a 1.18x margin, which is not a margin"
grep -A20 'systemd.user.timers.claude-session-sync' "$CLAUDE_NIX" | grep -q 'Persistent = true' \
  && ok "catches up a run missed while the laptop was asleep or off" \
  || nope "no Persistent — a shut laptop silently skips its runs"
grep -q 'ExecStart = "${pkgs.bash}/bin/bash ${syncSessions}"' "$CLAUDE_NIX" \
  && ok "ExecStart points at the archive's own bin/sync-sessions.sh" \
  || nope "ExecStart does not run the memory repo's sync-sessions.sh — the logic has been duplicated"
grep -q 'ConditionPathExists = syncSessions' "$CLAUDE_NIX" \
  && ok "a machine without the clone skips the unit instead of failing hourly" \
  || nope "no ConditionPathExists — a machine without the clone accrues a failed unit every hour"

# ── 4 · no threshold has been copied into nix ───────────────────────────────
echo "▶ Phase 4 · one source of truth for the sizes"
# Only the assignments matter; the prose comment is allowed to explain the
# window in words. Anything that looks like a size being handed to a command or
# bound to a name is a second source of truth waiting to drift.
if grep -vE '^\s*#' "$CLAUDE_NIX" | grep -qE '(41943040|104857600|83886080|"20M"|shard_threshold)'; then
  nope "a session size threshold has been written into claude.nix — it belongs in bin/session-limits.json"
else
  ok "no size threshold restated in nix"
fi

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
