#!/usr/bin/env bash
# test-system-protection-orphan-reaper.sh — verify the orphan reaper
# protects whitelisted essentials, does not kill in dry-run mode, and
# selectively kills non-whitelisted user orphans on --apply.
#
# Run: bash modules/test-system-protection-orphan-reaper.sh

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SELF_DIR/system-protection-orphan-reaper.sh"
WHITELIST="$SELF_DIR/system-protection-orphan-reaper.json"

fail() { echo "FAIL: $1" >&2; cleanup_test; exit 1; }
pass() { echo "  ✓ $1"; }

SPAWNED=()
TMP_DIR=""
cleanup_test() {
    [ "${#SPAWNED[@]}" -gt 0 ] && kill -9 "${SPAWNED[@]}" 2>/dev/null || true
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup_test EXIT INT TERM

echo "=== orphan-reaper engine ==="

# ─── PART A: STATIC ────────────────────────────────────────────
[ -x "$REAPER" ]    || fail "engine not executable: $REAPER"
[ -r "$WHITELIST" ] || fail "whitelist not readable: $WHITELIST"
pass "engine + whitelist present"

bash -n "$REAPER" || fail "engine has syntax errors"
pass "engine syntax valid"

jq -e '.comm_exact and .comm_substring and .cgroup_substring' "$WHITELIST" >/dev/null \
    || fail "whitelist missing required arrays"
pass "whitelist schema OK (comm_exact, comm_substring, cgroup_substring)"

# Sanity: a few essentials MUST be whitelisted, otherwise a sloppy edit
# could nuke the desktop. Pick the load-bearing ones from live evidence.
for must in plasmashell kwin dbus pipewire kwallet gvfsd dolphin konsole; do
    jq -e --arg n "$must" '
        (.comm_exact      // []) + (.comm_substring   // []) +
        (.exe_substring   // []) + (.argv_substring   // []) +
        (.cgroup_substring // [])
        | any(. as $e | $e | tostring | contains($n))
    ' "$WHITELIST" >/dev/null \
        || fail "essential '$must' is NOT whitelisted — desktop kill risk"
    pass "essential '$must' is whitelisted"
done

# ─── PART B: BEHAVIOUR ─────────────────────────────────────────
TMP_DIR="$(mktemp -d -t test-orphan-reaper.XXXXXX)"

# ── B.0 — baseline kill count sanity (regression for empty-comm bug) ──
# When the engine's comm/cgroup reads silently fail (e.g. the bash
# `$(< file 2>/dev/null)` parser quirk), every Plasma essential gets
# flagged for kill — 50+ candidates instead of ~0-5. That'd be catastrophic
# under --apply: the desktop session would be torn down. Assert the count
# is sane BEFORE spawning any test fake.
baseline=$("$REAPER" --dry-run 2>&1)
n_baseline=$(echo "$baseline" | awk '
    /^── KILL CANDIDATES — / {
        match($0, /[0-9]+/); print substr($0, RSTART, RLENGTH); exit
    }
    /^── no kill candidates ──$/ { print 0; exit }
')
n_baseline="${n_baseline:-0}"
if [ "$n_baseline" -gt 25 ]; then
    echo "$baseline" >&2
    fail "baseline kill candidates = $n_baseline (>25) — engine reads broken; would nuke desktop"
fi
pass "baseline candidate count sane (n=$n_baseline ≤ 25; >25 means whitelist-match bug)"

# Spawn a long-running fake whose argv[0] = $1 and whose argv contains
# $2 (a unique fingerprint). Same proven pattern as test_watcher_reap.sh
# in front/. Stdio severed so command substitution doesn't block.
spawn_fake() {
    local argv0="$1" fingerprint="$2"
    bash -c "exec -a '$argv0' bash -c 'trap : TERM INT HUP; while sleep 60; do :; done' fake '$fingerprint'" \
        </dev/null >/dev/null 2>&1 &
    local pid=$!
    SPAWNED+=("$pid")
    echo "$pid"
}

# Fingerprint that avoids matching anything in the whitelist or this
# script's path (a pkill -f from elsewhere mustn't catch us).
read -r FP < /proc/sys/kernel/random/uuid 2>/dev/null \
    || FP="reap-$$-$RANDOM-$(date +%s)"
FP="reap-fingerprint-$FP"

# A "non-essential" fake — argv[0] is just /tmp/.../noisemaker.
# This name does NOT appear in the whitelist, so reaper SHOULD pick it up.
# Snapshot whitelist: protect every currently-running user process. The test
# fakes spawned AFTER this snapshot get unique TMP_DIR-based argv that won't
# match — so apply kills only the test fakes, never the user's real orphans
# (this matters on long-running sessions: leaked geoclue demos, wl-paste,
# stale bash wrappers, etc. would otherwise be collateral damage).
SNAPSHOT_WL="$TMP_DIR/whitelist-snapshot.json"
SNAPSHOT_ARGV_LIST="$TMP_DIR/baseline-argvs.txt"
: > "$SNAPSHOT_ARGV_LIST"
for entry in /proc/[0-9]*; do
    spid="${entry#/proc/}"
    cmdline=$(tr '\0' ' ' < "/proc/$spid/cmdline" 2>/dev/null) || continue
    [ -z "$cmdline" ] && continue
    # Trim and store; the engine treats argv_substring as substring match,
    # so the full cmdline as the needle uniquely identifies this process.
    printf '%s\n' "${cmdline% }" >> "$SNAPSHOT_ARGV_LIST"
done
jq --rawfile snap "$SNAPSHOT_ARGV_LIST" '
    .argv_substring += ($snap | split("\n") | map(select(length > 0)))
' "$WHITELIST" > "$SNAPSHOT_WL"
[ -s "$SNAPSHOT_WL" ] || fail "could not build snapshot whitelist"
pass "snapshot whitelist built ($(wc -l < "$SNAPSHOT_ARGV_LIST") existing pids protected)"

victim_argv0="$TMP_DIR/noisemaker"
victim="$(spawn_fake "$victim_argv0" "$FP")"
sleep 0.3
[ -r "/proc/$victim/cmdline" ] || fail "victim fake (pid $victim) didn't survive"
pass "spawned non-essential fake (pid $victim, argv0=$victim_argv0)"

# Sanity: the fake actually qualifies as a user-orphan candidate
victim_ppid=$(awk '/^PPid:/ {print $2}' "/proc/$victim/status" 2>/dev/null)
victim_tty=$(awk '{print $7}' "/proc/$victim/stat" 2>/dev/null)
[ "$victim_tty" = "0" ] \
    || fail "victim has tty $victim_tty, expected 0 (no controlling tty)"
pass "victim has no controlling tty (tty_nr=0)"

# ── B.1 — dry-run lists the victim, does NOT kill ─────────────
out=$("$REAPER" --dry-run --whitelist "$SNAPSHOT_WL" 2>&1) || fail "dry-run exited non-zero"
echo "$out" | grep -q "$victim" \
    || fail "dry-run did not list victim pid $victim"
pass "dry-run lists victim as kill candidate"

[ -r "/proc/$victim/cmdline" ] \
    || fail "dry-run KILLED victim — must only list, never signal"
pass "dry-run did not kill victim"

# ── B.2 — apply with snapshot whitelist kills only the test fake ──
# Critical: real running processes (Plasma essentials, leaked daemons that
# happen to be candidates) are protected by the snapshot. Only post-snapshot
# fakes are killable.
out=$("$REAPER" --apply --whitelist "$SNAPSHOT_WL" 2>&1)
ec=$?
[ "$ec" = 0 ] || fail "--apply exited $ec, expected 0 (out: $out)"
sleep 0.4
if [ -r "/proc/$victim/cmdline" ]; then
    fail "--apply did NOT kill victim (pid $victim still alive)"
fi
pass "--apply killed victim"

# ── B.3 — whitelisted fake survives --apply ───────────────────
# Spawn a fake whose argv[0] basename matches a whitelist entry.
# 'plasmashell' is in comm_substring, so the comm of our fake bash
# would need to be 'plasmashell' for that match — but bash's comm is
# 'bash', so we instead embed 'plasmashell' in argv (matches argv_substring
# rule? no, that rule doesn't have plasmashell). Use cgroup_substring:
# our test bash inherits this shell's cgroup which lives under
# session.slice if launched from a login session — and session-N.scope
# IS in the whitelist. Verify by reading cgroup of the test shell.
my_cgroup=$(< /proc/self/cgroup)
case "$my_cgroup" in
    *session-*|*session.slice/*|*init.scope*|*background.slice/*)
        cgroup_already_whitelisted=true ;;
    *)
        cgroup_already_whitelisted=false ;;
esac

# Whichever path applies, we add a temporary whitelist with our victim's
# fingerprint so we can prove the protection mechanism end-to-end without
# depending on the test runner's cgroup. Build a copy of the SNAPSHOT
# whitelist (which already protects all real running processes) with an
# extra argv_substring entry for the test marker.
TEMP_WL="$TMP_DIR/whitelist-with-test-marker.json"
TEST_MARKER="ORPHAN_REAPER_TEST_PROTECTED_$RANDOM"
jq --arg m "$TEST_MARKER" '.argv_substring += [$m]' "$SNAPSHOT_WL" > "$TEMP_WL"
[ -s "$TEMP_WL" ] || fail "could not write temp whitelist"

protected="$(spawn_fake "$TMP_DIR/something" "$TEST_MARKER-$FP")"
sleep 0.3
[ -r "/proc/$protected/cmdline" ] || fail "protected fake (pid $protected) didn't start"
pass "spawned protected fake (pid $protected, marker=$TEST_MARKER)"

# Run apply with the temp whitelist
out=$("$REAPER" --apply --whitelist "$TEMP_WL" 2>&1)
ec=$?
[ "$ec" = 0 ] || fail "apply with temp whitelist exited $ec (out: $out)"
sleep 0.4

if [ ! -r "/proc/$protected/cmdline" ]; then
    fail "protected fake (pid $protected) was killed despite matching whitelist!"
fi
pass "whitelisted process survived --apply"
kill -9 "$protected" 2>/dev/null || true

# ── B.4 — verbose mode shows protected processes ──────────────
out=$("$REAPER" --dry-run --verbose 2>&1)
echo "$out" | grep -q "PROTECTED" \
    || fail "verbose mode did not print PROTECTED section"
pass "verbose mode lists protected processes"

echo ""
echo "=== orphan-reaper: PASS ==="
