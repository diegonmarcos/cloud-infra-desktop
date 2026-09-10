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
# modules/my-webserver/default.nix, 2026-08-10. Termux:API is not wired either
# (modules/packages.nix), so termux-job-scheduler is out too.
#
# The 2026-09-09 version of this archive used a SHELL START as its trigger and
# left a gap its own header named: a session that runs for days inside one
# shell never fires again. On this phone that is the normal case, not an edge
# case, and the archive fell 12 MiB behind overnight because of it. The
# primary trigger is now Claude Code's own lifecycle — Stop per turn, rate
# limited, and SessionEnd forced — declared in the settings SoT
# (da_my-ai/data/claude/settings.termux.json).
#
# So there are two things to protect. The SHELL START SITES remain as the
# secondary trigger and one of them silently missing is indistinguishable,
# from the outside, from an archive that is working; in particular the bash
# site is not redundant with the fish site — sshd hands out /bin/sh, which
# reads ~/.profile, which sources ~/.bashrc, and fish is never involved on
# that path. And the RATE GATE is what makes a per-turn hook affordable; if it
# regressed open, every assistant turn would push over mobile data, and if it
# regressed shut, the archive would stop and say nothing.
#
# Static assertions, a syntax check, and a real behavioural run of the gate
# against a sandbox archive. This host cannot evaluate an aarch64 nix-on-droid
# closure, so a green run here is not a green switch and does not pretend to
# be one.
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
grep -q 'nohup bash "\$0"' "$LAUNCHER" \
  && ok "detaches through bash, so a trigger never blocks on a push" \
  || nope "does not detach through bash — either it blocks the turn, or (with a bare nohup \"\$0\") the re-exec dies on a missing exec bit and the sync silently never runs"
grep -q '\[ -r "\$SYNC" \] || exit 0' "$LAUNCHER" \
  && ok "a device without the clone exits 0 instead of erroring on every shell start" \
  || nope "a missing clone is not handled — every shell start would print an error"
if grep -vE '^\s*#' "$LAUNCHER" | grep -qE '(41943040|104857600|83886080|20M)'; then
  nope "a session size threshold has been written into the launcher — it belongs in bin/session-limits.json"
else
  ok "no size threshold restated in the launcher"
fi

# ── 2 · both start sites ────────────────────────────────────────────────────
echo "▶ Phase 2 · shell start sites (secondary trigger)"
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

# ── 5 · the rate gate, as declared ─────────────────────────────────────────
# A per-turn hook is only affordable because of this gate, and the interval is
# a DATUM in the archive, not a number in this script — the launcher and the
# README have to be able to cite the same one.
echo "▶ Phase 5 · rate gate (what makes a per-turn trigger affordable)"
grep -q 'min_sync_interval_seconds' "$LAUNCHER" \
  && ok "reads the interval from the archive's bin/session-limits.json" \
  || nope "no interval read — a Stop hook would commit and push on every assistant turn"
if grep -vE '^\s*#' "$LAUNCHER" | grep -qE '\b(3600|900|60)\b'; then
  nope "an interval literal has been written into the launcher — it belongs in bin/session-limits.json"
else
  ok "no interval literal restated in the launcher"
fi
grep -q -- '--force' "$LAUNCHER" \
  && ok "honours --force, so SessionEnd can flush the tail inside the interval" \
  || nope "no --force — the end of a session waits for the next interval, which may be days"

# ── 6 · the gate actually behaves ──────────────────────────────────────────
# Static greps cannot tell a working gate from one that is stuck open or shut,
# and both failures are silent. Run it against a sandbox archive instead.
echo "▶ Phase 6 · rate gate behaviour (sandbox archive, no network)"
GATE_TMP="$(mktemp -d)"
trap 'rm -rf "$GATE_TMP"' EXIT
mkdir -p "$GATE_TMP/repo/bin" "$GATE_TMP/repo/.git" "$GATE_TMP/cache"
printf '{ "min_sync_interval_seconds": 3600 }\n' > "$GATE_TMP/repo/bin/session-limits.json"
printf '#!/usr/bin/env bash\necho ran >> "%s/ran.log"\n' "$GATE_TMP" > "$GATE_TMP/repo/bin/sync-sessions.sh"

# The launcher detaches, so every call needs a moment before the count is read.
runs() { sleep 1; grep -c . "$GATE_TMP/ran.log" 2>/dev/null || echo 0; }
fire() { CLAUDE_MEMORY_REPO="$GATE_TMP/repo" XDG_CACHE_HOME="$GATE_TMP/cache" bash "$LAUNCHER" "$@"; }
age_stamp() { touch -d '3 hours ago' "$GATE_TMP/cache/claude-sync-sessions.stamp"; }

fire;         [ "$(runs)" = 1 ] && ok "first call ever syncs" || nope "first call did not sync"
fire;         [ "$(runs)" = 1 ] && ok "a second call inside the interval is skipped" || nope "gate is stuck OPEN — every turn would push"
fire --force; [ "$(runs)" = 2 ] && ok "--force syncs inside the interval" || nope "--force is ignored — SessionEnd cannot flush the tail"
age_stamp; fire; [ "$(runs)" = 3 ] && ok "a stamp older than the interval syncs" || nope "gate is stuck SHUT — the archive would stop silently"
# Fail OPEN, never shut: a missing or malformed datum must mean "sync more
# often". Silently never syncing again is the failure this trigger replaces.
printf 'not json\n' > "$GATE_TMP/repo/bin/session-limits.json"; age_stamp; fire
[ "$(runs)" = 4 ] && ok "a malformed session-limits.json fails OPEN" || nope "a malformed limits file stops the archive dead"
rm -f "$GATE_TMP/repo/bin/session-limits.json"; fire
[ "$(runs)" = 5 ] && ok "a missing session-limits.json fails OPEN" || nope "a missing limits file stops the archive dead"
CLAUDE_MEMORY_REPO="$GATE_TMP/nowhere" XDG_CACHE_HOME="$GATE_TMP/cache" bash "$LAUNCHER" \
  && ok "a device with no clone exits 0" || nope "a device with no clone errors on every turn"
[ "$(runs)" = 5 ] && ok "and syncs nothing" || nope "it synced against a repo that is not there"

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
