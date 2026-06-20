#!/usr/bin/env bash
# test-claude-cleanup.sh — verify claude-malloc / claude-termux supervision
# and claude-orphan-sweep cleanup behaviour.
#
# Run AFTER `./build.sh switch` so the new wrappers are deployed.
#   bash test-claude-cleanup.sh
#
# Exit 0 = all pass, 1 = any fail.

set -u

pass=0
fail=0
skip=0
run() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then
    echo "[OK]   $name"
    pass=$((pass + 1))
  else
    echo "[FAIL] $name"
    fail=$((fail + 1))
  fi
}

# run_or_skip: only run $testfn if $precond succeeds; otherwise SKIP (not FAIL).
# Used for tests with an environmental precondition the runner can't satisfy
# (e.g. orphan-reparent-to-PID1, impossible while a subreaper ancestor exists).
run_or_skip() {
  local name=$1 precond=$2 testfn=$3
  if ! "$precond" >/dev/null 2>&1; then
    echo "[SKIP] $name ($SKIP_REASON)"
    skip=$((skip + 1))
    return
  fi
  run "$name" "$testfn"
}

# Precondition: can this environment orphan a process to PPID==1? A subreaper
# ancestor (e.g. a `tini -s` that launched the current session, or a proot that
# reparents to a non-1 reaper) intercepts orphans first. Spawn a forced orphan
# and check where it lands. Sets SKIP_REASON on failure.
SKIP_REASON=""
env_can_orphan_to_pid1() {
  local s; s=$(command -v setsid 2>/dev/null) || { SKIP_REASON="setsid unavailable"; return 1; }
  "$s" --fork sleep 3 </dev/null >/dev/null 2>&1 &
  sleep 1
  local p ppid found=1
  for p in /proc/[0-9]*; do
    [ "$(cat "$p/comm" 2>/dev/null)" = "sleep" ] || continue
    tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "sleep 3" || continue
    ppid=$(awk '/^PPid:/{print $2}' "$p/status" 2>/dev/null)
    [ "$ppid" = "1" ] && found=0
    kill "${p##*/}" 2>/dev/null || true
  done
  [ "$found" = "0" ] || SKIP_REASON="no PID-1 reparenting here (subreaper ancestor, e.g. the live tini-launched session, or proot reparents elsewhere)"
  return "$found"
}

# Precondition for the end-to-end sweep test. CRITICAL SAFETY: the test invokes
# the REAL deployed claude-orphan-sweep. A session-based (field $6) sweep does
# `kill -- -<session>`, which would take down the whole LOGIN SESSION (fish +
# every claude). So we ONLY run the end-to-end if (a) the env can orphan to
# PID 1 AND (b) the deployed sweep is the corrected process-group ($5) version.
# Otherwise SKIP — never fire a login-killing sweep from a test.
sweep_e2e_precond() {
  env_can_orphan_to_pid1 || return 1
  if ! { grep -qF 'print $5' "$CS" && ! grep -qF 'print $6' "$CS"; }; then
    SKIP_REASON="deployed sweeper still session-based (\$6) — run build.sh switch to deploy the pgrp (\$5) fix before this can run safely"
    return 1
  fi
  return 0
}

# ── Locate the deployed wrappers ────────────────────────────────────────
CM=$(command -v claude-malloc 2>/dev/null) || { echo "claude-malloc not on PATH"; exit 1; }
CT=$(command -v claude-termux 2>/dev/null) || { echo "claude-termux not on PATH"; exit 1; }
CS=$(command -v claude-orphan-sweep 2>/dev/null) || { echo "claude-orphan-sweep not on PATH"; exit 1; }

# ── Structural assertions on the deployed scripts ───────────────────────
# Supervision is setpriv --pdeathsig only. tini is DELIBERATELY absent: under
# proot its reaper waitpid(-1) gets ENOSYS and aborts with
# "Error while waiting for pids: 'Function not implemented'", killing claude.
# Whole-tree teardown is delegated to claude-orphan-sweep (PPID=1 + process
# group kill). NB: a `tini` substring may legitimately appear in the sweeper's
# kill-list, so we assert against the actual `bin/tini` invocation, not the word.
run "claude-malloc does NOT invoke tini"  bash -c '! grep -qE "bin/tini" "$1"' _ "$CM"
run "claude-malloc uses --pdeathsig"      grep -q -- '--pdeathsig' "$CM"
run "claude-malloc calls sweeper"         grep -q 'claude-orphan-sweep' "$CM"
run "claude-malloc runs claude in fg"     bash -c '! grep -E "setpriv.*&\\s*\$" "$1"' _ "$CM"

run "claude-termux does NOT invoke tini"  bash -c '! grep -qE "bin/tini" "$1"' _ "$CT"
run "claude-termux uses --pdeathsig"      grep -q -- '--pdeathsig' "$CT"
run "claude-termux runs claude in fg"     bash -c '! grep -E "setpriv.*&\\s*\$" "$1"' _ "$CT"

run "sweeper bash syntax OK"             bash -n "$CS"

# Sweeper must tear down by PROCESS GROUP (stat field 5 / pgrp), NOT session
# (field 6). fish job control puts the claude subtree in its own pgroup while
# it stays in the shared login session, so `kill -- -<session>` both misses
# claude and would hit the login group. Regression guard for that exact bug.
run "sweeper kills by pgrp (\$5) not session (\$6)" \
  bash -c 'grep -qF "print \$5" "$1" && ! grep -qF "print \$6" "$1"' _ "$CS"

# ── Sweeper is safe / idempotent when there are no orphans ──────────────
test_sweeper_idempotent() { "$CS" >/dev/null 2>&1; }
run "sweeper safe when no orphans" test_sweeper_idempotent

# ── MECHANISM TEST: pgrp-kill reaps a non-session-leader subtree ─────────
# Proves the primitive the fix relies on: a process-group leader that is NOT a
# session leader (pgid != sid, exactly the claude topology) is fully reaped by
# `kill -- -<pgid>`. No PID-1 orphaning needed, so this always runs.
test_pgrp_kill_reaps_subtree() {
  local out
  out=$(
    set -m   # job control ON → backgrounded job gets its own process group
    bash -c 'sleep 91 & sleep 91 & wait' &
    job=$!
    sleep 1
    s=$(cat "/proc/$job/stat" 2>/dev/null); r=${s#*) }; set -- $r
    pgid=$3; sid=$4
    members() { local tgt=$1 n=0 q ss rr; for q in /proc/[0-9]*; do
      ss=$(cat "$q/stat" 2>/dev/null) || continue; rr=${ss#*) }; set -- $rr
      [ "$3" = "$tgt" ] 2>/dev/null && n=$((n + 1)); done; echo "$n"; }
    before=$(members "$pgid")
    distinct=no; [ "$pgid" != "$sid" ] && distinct=yes
    kill -- -"$pgid" 2>/dev/null
    sleep 1
    after=$(members "$pgid")
    kill -- -"$pgid" 2>/dev/null   # cleanup
    echo "$distinct $before $after"
  )
  set -- $out
  # realistic topology (pgid != sid), subtree present (>=3), fully reaped (0)
  [ "${1:-}" = "yes" ] && [ "${2:-0}" -ge 3 ] && [ "${3:-1}" = "0" ]
}
run "pgrp-kill reaps non-session-leader subtree" test_pgrp_kill_reaps_subtree

# ── /proc helper: count processes whose cmdline contains a marker ────────
# pgrep is unreliable on Termux/proot (blocks /proc/uptime), so scan /proc.
count_marker() {
  local marker=$1 n=0 p
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "$marker" && n=$((n+1)) || true
  done
  echo "$n"
}

# ── INTEGRATION TEST 1: pdeathsig reaps the direct child ─────────────────
# New contract (no tini): setpriv --pdeathsig TERM execs claude as the DIRECT
# child of the wrapper. When the wrapper dies, the kernel SIGTERMs claude.
# Use a fake that EXECs sleep, so the marker process IS the direct child.
test_pdeathsig_kills_direct_child() {
  local tmp; tmp=$(mktemp -d) || return 1
  local marker="claudecleanup_$$_$RANDOM"
  local fake="$tmp/$marker"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
exec sleep 999
EOF
  chmod +x "$fake"

  local setpriv
  setpriv=$(grep -oE '/nix/store/[^ ]*util-linux[^ ]*/bin/setpriv' "$CM" | head -1)
  [ -x "$setpriv" ] || { rm -rf "$tmp"; return 1; }

  # Same shape as the deployed wrapper: synchronous foreground setpriv, no tini.
  bash -c '"$1" --pdeathsig TERM -- "$2" </dev/null' _ "$setpriv" "$fake" &
  local wpid=$!

  sleep 2
  local before; before=$(count_marker "$marker")
  if [ "$before" -lt 1 ]; then
    kill "$wpid" 2>/dev/null || true
    rm -rf "$tmp"
    return 1
  fi

  kill -TERM "$wpid" 2>/dev/null || true
  sleep 3

  local after; after=$(count_marker "$marker")
  rm -rf "$tmp"
  [ "$after" = "0" ]
}
run "pdeathsig reaps direct child on outer SIGTERM" test_pdeathsig_kills_direct_child

# ── INTEGRATION TEST 2: orphan-sweep tears down an orphaned session ──────
# End-to-end: the REAL deployed claude-orphan-sweep tears down a genuinely
# orphaned (PPID==1) claude subtree. We reproduce the live topology exactly:
# a comm="claude" leader (bash exec'd through a symlink named "claude") in its
# OWN process group but the SHARED login session (pgid != sid — via `set -m`
# job control), spawning two REAL `sleep` children (renaming a coreutils
# multicall binary breaks its argv0 dispatch). A launcher that backgrounds the
# job then exits leaves the leader at PPID==1 while preserving its pgroup —
# so the sweep must match comm + PPID==1 and `kill -- -<pgrp>` the subtree. The
# distinct pgroup confines the kill to this tree; the login session is untouched.
#
# This is the case the field-6→field-5 fix exists for: a session-leader leader
# (pgid==sid) would pass even the buggy sweeper, so we deliberately force
# pgid != sid here.
#
# GATED by env_can_orphan_to_pid1: while a subreaper ancestor exists (e.g. the
# current session was launched by the OLD `tini -s` wrapper, which intercepts
# orphans before PID 1), nothing can reach PPID==1, so the precondition is
# unsatisfiable and this SKIPs. It runs for real once claude is relaunched
# under the tini-free wrapper.
test_sweeper_kills_orphaned_session() {
  local tmp; tmp=$(mktemp -d) || return 1
  local bash_bin; bash_bin=$(command -v bash 2>/dev/null)
  [ -x "$bash_bin" ] || { rm -rf "$tmp"; return 1; }

  ln -s "$bash_bin" "$tmp/claude" || { rm -rf "$tmp"; return 1; }
  cat > "$tmp/leader.sh" <<'EOF'
sleep 999 &
sleep 999 &
wait
EOF

  # Launcher: job control ON so the leader gets its own pgroup; background it,
  # disown, and exit → leader reparents to PID 1 (pgroup preserved).
  "$bash_bin" -c 'set -m; "'"$tmp"'/claude" "'"$tmp"'/leader.sh" </dev/null >/dev/null 2>&1 & disown' \
    </dev/null >/dev/null 2>&1
  sleep 2

  # Locate the orphaned leader: comm=claude, PPID==1, cmdline references our tmp.
  local p leader="" pgid=""
  for p in /proc/[0-9]*; do
    [ "$(cat "$p/comm" 2>/dev/null)" = "claude" ] || continue
    [ "$(awk '/^PPid:/{print $2}' "$p/status" 2>/dev/null)" = "1" ] || continue
    tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "$tmp" || continue
    leader=${p##*/}
    # field 5 of stat = pgrp (strip "(comm)" first for safety)
    local s r; s=$(cat "$p/stat" 2>/dev/null); r=${s#*) }; set -- $r; pgid=$3
    break
  done
  [ -n "$leader" ] && [ -n "$pgid" ] || { kill -- -"${pgid:-$$}" 2>/dev/null; rm -rf "$tmp"; return 1; }

  # Count members of the leader's PROCESS GROUP (what the sweep must reap).
  count_pgrp() { local tgt=$1 n=0 q s r; for q in /proc/[0-9]*; do
    s=$(cat "$q/stat" 2>/dev/null) || continue; r=${s#*) }; set -- $r
    [ "$3" = "$tgt" ] 2>/dev/null && n=$((n + 1)); done; echo "$n"; }

  local before; before=$(count_pgrp "$pgid")
  [ "$before" -ge 1 ] || { kill -- -"$pgid" 2>/dev/null; rm -rf "$tmp"; return 1; }

  "$CS" >/dev/null 2>&1 || true   # run the real claude-orphan-sweep
  sleep 3

  local after; after=$(count_pgrp "$pgid")
  kill -- -"$pgid" 2>/dev/null || true   # cleanup if the sweep didn't
  rm -rf "$tmp"
  [ "$after" = "0" ]
}
run_or_skip "orphan-sweep tears down orphaned claude subtree" \
  sweep_e2e_precond test_sweeper_kills_orphaned_session

echo
echo "Result: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
