#!/usr/bin/env bash
# claude-sync-sessions.sh — fire cloud-data-my-ai-memory/bin/sync-sessions.sh
# from a shell start. Deployed on PATH by claude/claude.nix
# (pkgs.writeShellApplication), called from the two shell start sites this
# device already uses for exactly this purpose.
#
# WHY A SHELL START AND NOT A TIMER.
#
# nix-on-droid runs no systemd user session, so ba_flakes_desktop's
# systemd.user.timer has no counterpart here. systemd is not the only thing
# missing: com.termux.nix — the app this flake targets — ships no apt/dpkg
# layer at all, so termux-services (runit, sv-enable, runsvdir) can never be
# installed on it either. That finding is recorded in
# modules/my-webserver/default.nix, dated 2026-08-10, and it names "the fish
# interactive-shell hook" as the actual auto-start path on this device.
# modules/cloud-ide-sshd/default.nix reaches for the same hook for the same
# reason. There is no periodic scheduler on this phone to reuse, so this reuses
# the trigger that already carries two other services rather than inventing a
# third mechanism that would need its own watchdog.
#
# It is a TRIGGER, not a schedule, and the distinction is worth stating plainly.
# A transcript only grows while a Claude Code session is running, and a session
# on this device can only be started from a shell, so every burst of growth is
# preceded by one of these. What it does NOT cover is a single session that runs
# for days inside one shell: nothing fires again until the next shell opens.
# That gap costs archive freshness, not safety — sync-sessions.sh shards BEFORE
# it stages, so whenever it next runs an oversized transcript is untracked and
# ignored rather than committed, and bin/hooks/pre-commit (installed by
# claude.nix via core.hooksPath) refuses any hand-made commit in the meantime.
#
# Detached and locked, because a shell start must not block and shells are
# opened in bursts:
#   - nohup + background, so a sync outlives the terminal that spawned it.
#     Android reaps a terminal's process group the moment the terminal goes
#     away, and a sync killed mid-push leaves a local commit that only the next
#     run repairs.
#   - flock -n, so ten terminals in ten seconds produce one sync rather than ten
#     racing on .git/index. The kernel drops the lock when the holder dies, so a
#     crashed run cannot wedge the archive shut — the same reasoning
#     bin/shard-big-sessions.sh gives for its own lock.
#
# Sizes and archiving steps are deliberately absent from this file. The
# thresholds live in the memory repo's bin/session-limits.json and the procedure
# lives in its bin/sync-sessions.sh; this only decides WHEN.
set -euo pipefail

REPO="${CLAUDE_MEMORY_REPO:-$HOME/git/cloud-data-my-ai-memory}"
SYNC="$REPO/bin/sync-sessions.sh"
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/claude-sync-sessions.log"

# No clone, nothing to archive. Silent and successful: this runs on every shell
# start, and a device that has not cloned the memory repo is not broken.
[ -r "$SYNC" ] || exit 0

# First pass detaches and returns immediately; the second pass does the work.
if [ -z "${CLAUDE_SYNC_SESSIONS_DETACHED:-}" ]; then
  CLAUDE_SYNC_SESSIONS_DETACHED=1 nohup "$0" >/dev/null 2>&1 </dev/null &
  exit 0
fi

mkdir -p "$(dirname "$LOG")"
# Append rather than truncate: a run that failed three shells ago is exactly
# what a human goes looking for. A few hundred bytes per shell start is not a
# growth problem worth a rotation mechanism.
exec >>"$LOG" 2>&1
echo "=== $(date -Iseconds) claude-sync-sessions"
flock -n "$REPO/.git/claude-sync-sessions.lock" bash "$SYNC" \
  || echo "[claude-sync] did not complete: another run holds the lock, or the sync itself failed (see above)"
