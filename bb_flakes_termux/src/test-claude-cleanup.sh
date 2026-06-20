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

# ── Locate the deployed wrappers ────────────────────────────────────────
CM=$(command -v claude-malloc 2>/dev/null) || { echo "claude-malloc not on PATH"; exit 1; }
CT=$(command -v claude-termux 2>/dev/null) || { echo "claude-termux not on PATH"; exit 1; }
CS=$(command -v claude-orphan-sweep 2>/dev/null) || { echo "claude-orphan-sweep not on PATH"; exit 1; }

# ── Structural assertions on the deployed scripts ───────────────────────
# Supervision is setpriv --pdeathsig only. tini is DELIBERATELY absent: under
# proot its reaper waitpid(-1) gets ENOSYS and aborts with
# "Error while waiting for pids: 'Function not implemented'", killing claude.
# Whole-tree teardown is delegated to claude-orphan-sweep (PPID=1 + session
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

# ── Sweeper is safe / idempotent when there are no orphans ──────────────
test_sweeper_idempotent() { "$CS" >/dev/null 2>&1; }
run "sweeper safe when no orphans" test_sweeper_idempotent

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
# Whole-tree teardown is the sweeper's job (it replaces tini's subtree reaping).
# It targets PPID=1 processes whose comm matches claude*/tini and kills their
# whole SESSION GROUP (`kill -- -SID`). We build a leader with comm="claude" by
# execing bash through a symlink named "claude", spawning two REAL `sleep`
# children (renaming a coreutils multicall binary breaks its argv0 dispatch, so
# children are identified by SESSION id — exactly what the group-kill targets),
# and orphan it via `setsid --fork`. The fresh session isolates the group kill
# to this tree only — never the live claude session.
#
# GATED by env_can_orphan_to_pid1: while a subreaper ancestor exists (e.g. the
# current session was launched by the OLD `tini -s` wrapper, which intercepts
# orphans before PID 1), no process can reach PPID==1, so the sweeper's
# precondition is unsatisfiable and the test SKIPs rather than failing. It runs
# for real once claude is relaunched under the tini-free wrapper.
test_sweeper_kills_orphaned_session() {
  local tmp; tmp=$(mktemp -d) || return 1
  local setsid bash_bin
  setsid=$(command -v setsid 2>/dev/null)
  bash_bin=$(command -v bash 2>/dev/null)
  { [ -x "$setsid" ] && [ -x "$bash_bin" ]; } || { rm -rf "$tmp"; return 1; }

  ln -s "$bash_bin" "$tmp/claude" || { rm -rf "$tmp"; return 1; }
  cat > "$tmp/leader.sh" <<'EOF'
sleep 999 &
sleep 999 &
wait
EOF

  "$setsid" --fork "$tmp/claude" "$tmp/leader.sh" </dev/null >/dev/null 2>&1 &
  sleep 2

  # Locate the leader (comm=claude, cmdline references our tmp). As a setsid
  # session leader its SID == its own PID; children inherit that session.
  local p leader=""
  for p in /proc/[0-9]*; do
    [ "$(cat "$p/comm" 2>/dev/null)" = "claude" ] || continue
    tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "$tmp" || continue
    leader=${p##*/}; break
  done
  [ -n "$leader" ] || { rm -rf "$tmp"; return 1; }

  # /proc/<pid>/stat field 6 = session id (comm here has no spaces → safe).
  count_session() { local n=0 q; for q in /proc/[0-9]*; do
    [ "$(awk '{print $6}' "$q/stat" 2>/dev/null)" = "$1" ] && n=$((n + 1)); done; echo "$n"; }

  local before; before=$(count_session "$leader")
  if [ "$before" -lt 1 ]; then
    kill -- -"$leader" 2>/dev/null || true
    rm -rf "$tmp"; return 1
  fi

  "$CS" >/dev/null 2>&1 || true   # run the real claude-orphan-sweep
  sleep 3

  local after; after=$(count_session "$leader")
  kill -- -"$leader" 2>/dev/null || true   # cleanup if the sweep didn't
  rm -rf "$tmp"
  [ "$after" = "0" ]
}
run_or_skip "orphan-sweep tears down orphaned claude session" \
  env_can_orphan_to_pid1 test_sweeper_kills_orphaned_session

echo
echo "Result: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
