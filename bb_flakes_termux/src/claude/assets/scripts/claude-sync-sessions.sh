#!/usr/bin/env bash
# claude-sync-sessions.sh — fire cloud-data-my-ai-memory/bin/sync-sessions.sh.
# Deployed on PATH by claude/claude.nix (pkgs.writeShellApplication).
#
# WHY CLAUDE CODE'S OWN HOOKS AND NOT A SCHEDULER.
#
# There is no scheduler on this device to reuse. nix-on-droid runs no systemd
# user session, so ba_flakes_desktop's systemd.user.timer has no counterpart
# here; com.termux.nix ships no apt/dpkg layer, so termux-services (runit,
# sv-enable, runsvdir) can never be installed on it either — recorded in
# modules/my-webserver/default.nix, dated 2026-08-10. Termux:API is not wired
# either (modules/packages.nix: the upstream C bridge needs a bionic-only
# header the nix-on-droid build env does not expose), so termux-job-scheduler
# is not on the table. crontab on this device answers "must be suid to work
# properly".
#
# The 2026-09-09 attempt reached for a SHELL START instead, which is what
# already carries my-webserver and cloud-ide-sshd. Its own header named the
# gap it was leaving: "a single session that runs for days inside one shell —
# nothing fires again until the next shell opens". That gap is not an edge
# case on this phone, it is the normal case. A shell start is a proxy for
# "somebody is about to work"; it is not a proxy for "a transcript is
# growing", and the two come apart exactly when a session is long, which is
# when the archive matters most.
#
# So the trigger is now Claude Code itself. A transcript grows if and only if
# a session is running, and Claude Code is the process writing it, so its
# hooks fire when there is new data and never when there is not:
#
#   Stop        after every assistant turn — the during-session heartbeat,
#               rate-limited below. This is what makes a session that is never
#               cleanly exited (killed, OOM, phone rebooted) cost at most one
#               interval instead of the whole session.
#   SessionEnd  --force, on a clean exit. The tail of a session is the data
#               most likely to sit unarchived for days afterwards, and it is
#               the one moment the interval floor would otherwise skip.
#
# Both are declared in da_my-ai/data/claude/settings.termux.json, which is the
# SoT this device's ~/.claude/settings.json is merged from. The shell start
# sites stay as they are: they cost nothing, and they cover a device that has
# not opened Claude Code since a reboot.
#
# THE FLOOR. Stop fires per turn, and an unguarded sync there would be a
# commit and a push per assistant response, over mobile data. So the first
# pass consults a stamp file and returns immediately unless the interval in
# the archive's own bin/session-limits.json has elapsed. The stamp is touched
# when a run is STARTED, not when it succeeds, so a sync that keeps failing
# retries hourly rather than on every turn.
#
# Detached and locked, because a hook must not block and turns come in bursts:
#   - nohup + background, so a sync outlives the terminal or the session that
#     spawned it. Android reaps a terminal's process group the moment the
#     terminal goes away, and a sync killed mid-push leaves a local commit
#     that only the next run repairs.
#   - flock -n, so overlapping triggers produce one sync rather than several
#     racing on .git/index. The kernel drops the lock when the holder dies, so
#     a crashed run cannot wedge the archive shut — the same reasoning
#     bin/shard-big-sessions.sh gives for its own lock.
#
# Sizes and archiving steps are deliberately absent from this file. The
# numbers live in the memory repo's bin/session-limits.json and the procedure
# lives in its bin/sync-sessions.sh; this only decides WHEN.
set -euo pipefail

REPO="${CLAUDE_MEMORY_REPO:-$HOME/git/cloud-data-my-ai-memory}"
SYNC="$REPO/bin/sync-sessions.sh"
LIMITS="$REPO/bin/session-limits.json"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
LOG="$CACHE/claude-sync-sessions.log"
STAMP="$CACHE/claude-sync-sessions.stamp"

# No clone, nothing to archive. Silent and successful: this runs from a hook
# on every turn, and a device that has not cloned the memory repo is not
# broken.
[ -r "$SYNC" ] || exit 0

# First pass decides and detaches, and must stay fast — Claude Code waits for
# it before continuing the turn. The second pass does the work.
if [ -z "${CLAUDE_SYNC_SESSIONS_DETACHED:-}" ]; then
  if [ "${1:-}" != "--force" ] && [ -e "$STAMP" ]; then
    # Fail OPEN if the interval cannot be read. A missing or malformed datum
    # must mean "sync more often", never "never sync again" — silently never
    # syncing is the precise failure this trigger exists to end.
    interval="$(jq -r '.min_sync_interval_seconds // empty' "$LIMITS" 2>/dev/null || true)"
    if [ -n "$interval" ]; then
      age=$(( $(date +%s) - $(stat -c %Y "$STAMP") ))
      [ "$age" -ge "$interval" ] || exit 0
    fi
  fi

  mkdir -p "$CACHE"
  touch "$STAMP"
  # Re-exec through bash rather than `nohup "$0"`: $0 only executes itself if
  # the exec bit survived, and it does not in the source tree, so the detach
  # failed into /dev/null and the sync silently never ran when this file was
  # exercised outside nix. A trigger that no-ops without saying so is the bug
  # this whole script exists to end.
  CLAUDE_SYNC_SESSIONS_DETACHED=1 nohup bash "$0" >/dev/null 2>&1 </dev/null &
  exit 0
fi

# Append rather than truncate: a run that failed three hours ago is exactly
# what a human goes looking for. The interval floor above keeps this to a
# handful of entries a day, so there is nothing here worth a rotation
# mechanism. Skipped triggers never reach this file — the stamp's mtime is
# the record of the last attempt, the log is the record of its outcome.
exec >>"$LOG" 2>&1
echo "=== $(date -Iseconds) claude-sync-sessions"
flock -n "$REPO/.git/claude-sync-sessions.lock" bash "$SYNC" \
  || echo "[claude-sync] did not complete: another run holds the lock, or the sync itself failed (see above)"
