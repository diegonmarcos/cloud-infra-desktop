#!/usr/bin/env bash
# ============================================================================
# claude-session-sync.test.sh — the transcript archive's wiring, on galaxy
# ----------------------------------------------------------------------------
# Same archive as ba_flakes_desktop/src/claude/claude-session-sync.test.sh
# guards, different device and a genuinely different mechanism.
#
# THERE IS NO TIMER ON THIS DEVICE AND THERE CANNOT BE ONE. nix-on-droid runs
# no systemd user session, and com.termux.nix ships no apt/dpkg layer, so
# termux-services (runit, sv-enable) can never be installed either — see
# modules/my-webserver/default.nix, 2026-08-10. The two triggers this phone
# actually has are a device boot and a shell start, and the archive uses the
# second one because a transcript only grows while a session runs and a session
# can only be started from a shell.
#
# That makes the START SITES the thing to protect: one of them silently missing
# is indistinguishable, from the outside, from an archive that is working. In
# particular the bash site is not redundant with the fish site — sshd hands out
# /bin/sh, which reads ~/.profile, which sources ~/.bashrc, and fish is never
# involved on that path, so dropping it would blind the archive to every
# session started from the Cloud IDE.
#
# Static assertions plus a real syntax check of the launcher. This host cannot
# evaluate an aarch64 nix-on-droid closure, so a green run here is not a green
# switch and does not pretend to be one.
# ============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_NIX="$DIR/claude.nix"
LAUNCHER="$DIR/assets/scripts/claude-sync-sessions.sh"
FISH_INIT="$DIR/../modules/programs/shells/fish/interactiveShellInit.fish"
BASH_NIX="$DIR/../modules/programs/shells/bash.nix"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
nope() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "▶ claude-session-sync.test.sh — transcript archive wiring (galaxy)"
[ -f "$CLAUDE_NIX" ] || { nope "claude.nix missing at $CLAUDE_NIX"; exit 1; }

# ── 1 · the launcher ────────────────────────────────────────────────────────
echo "▶ Phase 1 · claude-sync-sessions launcher"
[ -f "$LAUNCHER" ] && ok "launcher present" || { nope "launcher missing at $LAUNCHER"; exit 1; }
bash -n "$LAUNCHER" && ok "launcher: bash syntax" || nope "launcher: bash syntax"

grep -q 'bin/sync-sessions.sh' "$LAUNCHER" \
  && ok "delegates to the archive's own bin/sync-sessions.sh" \
  || nope "launcher does not call sync-sessions.sh — the archiving steps have been reimplemented"
grep -q 'flock -n' "$LAUNCHER" \
  && ok "takes a non-blocking lock — a burst of shells produces one sync" \
  || nope "no lock — ten terminals in ten seconds race on .git/index"
grep -q 'nohup "\$0"' "$LAUNCHER" \
  && ok "detaches, so a shell start never blocks on a push" \
  || nope "does not detach — every terminal open waits for a git push over the mesh"
grep -q '\[ -r "\$SYNC" \] || exit 0' "$LAUNCHER" \
  && ok "a device without the clone exits 0 instead of erroring on every shell start" \
  || nope "a missing clone is not handled — every shell start would print an error"
if grep -vE '^\s*#' "$LAUNCHER" | grep -qE '(41943040|104857600|83886080|20M)'; then
  nope "a session size threshold has been written into the launcher — it belongs in bin/session-limits.json"
else
  ok "no size threshold restated in the launcher"
fi

# ── 2 · both start sites ────────────────────────────────────────────────────
echo "▶ Phase 2 · shell start sites (this device has no scheduler)"
grep -q 'command -q claude-sync-sessions; and claude-sync-sessions' "$FISH_INIT" \
  && ok "fish start site present (terminal sessions)" \
  || nope "fish start site missing — terminal sessions never trigger the archive"
grep -q 'claude-sync-sessions' "$BASH_NIX" \
  && ok "bash start site present (ssh / Cloud IDE sessions)" \
  || nope "bash start site missing — sessions started over ssh never trigger the archive"
grep -q 'home.packages = \[ claudeSyncSessionsPkg \]' "$CLAUDE_NIX" \
  && ok "the launcher is on PATH, so both \`command -v\` guards can fire" \
  || nope "the launcher is not in home.packages — both start sites silently no-op forever"

# ── 3 · the pre-commit hook is armed, and cannot break a switch ─────────────
echo "▶ Phase 3 · core.hooksPath"
grep -q 'config core.hooksPath bin/hooks' "$CLAUDE_NIX" \
  && ok "core.hooksPath is asserted on every switch" \
  || nope "core.hooksPath is not set — a fresh clone commits oversized blobs unchecked"
grep -A3 'config core.hooksPath bin/hooks' "$CLAUDE_NIX" | grep -q '|| echo' \
  && ok "the git call degrades to a warning instead of aborting the switch" \
  || nope "the git call is unguarded — a failure here kills a home-manager switch on the phone"

# ── 4 · one name for this device ────────────────────────────────────────────
echo "▶ Phase 4 · instance identity"
grep -q 'instance = "galaxy";' "$CLAUDE_NIX" \
  && ok "the device name is one binding" \
  || nope "no single `instance` binding — the name is spelled out per site again"
if [ "$(grep -c '"galaxy"' "$CLAUDE_NIX")" -eq 1 ]; then
  ok "and it is written exactly once"
else
  nope "\"galaxy\" appears more than once in claude.nix — a second way of naming the same device"
fi

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
