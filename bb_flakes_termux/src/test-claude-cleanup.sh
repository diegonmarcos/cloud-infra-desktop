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

# ── Locate the deployed wrappers ────────────────────────────────────────
CM=$(command -v claude-malloc 2>/dev/null) || { echo "claude-malloc not on PATH"; exit 1; }
CT=$(command -v claude-termux 2>/dev/null) || { echo "claude-termux not on PATH"; exit 1; }
CS=$(command -v claude-orphan-sweep 2>/dev/null) || { echo "claude-orphan-sweep not on PATH"; exit 1; }

# ── Structural assertions on the deployed scripts ───────────────────────
run "claude-malloc invokes tini -s"      grep -q -- 'tini.*-s'  "$CM"
run "claude-malloc uses --pdeathsig"     grep -q -- '--pdeathsig' "$CM"
run "claude-malloc calls sweeper"        grep -q 'claude-orphan-sweep' "$CM"
run "claude-malloc runs claude in fg"    bash -c '! grep -E "tini.*&\\s*\$" "$1"' _ "$CM"

run "claude-termux invokes tini -s"      grep -q -- 'tini.*-s'  "$CT"
run "claude-termux uses --pdeathsig"     grep -q -- '--pdeathsig' "$CT"
run "claude-termux runs claude in fg"    bash -c '! grep -E "tini.*&\\s*\$" "$1"' _ "$CT"

run "sweeper bash syntax OK"             bash -n "$CS"

# ── Sweeper is safe / idempotent when there are no orphans ──────────────
test_sweeper_idempotent() { "$CS" >/dev/null 2>&1; }
run "sweeper safe when no orphans" test_sweeper_idempotent

# ── INTEGRATION TEST ────────────────────────────────────────────────────
# Replicate the supervision pattern from claude-malloc against a fake
# claude binary that spawns 3 long-running children. SIGTERM the outer
# bash wrapper and verify all children are gone within the grace window
# (pdeathsig → tini → claude pgroup).
test_supervision_kills_children() {
  local tmp; tmp=$(mktemp -d) || return 1
  # Unique marker in cmdline so we can find these procs in /proc without
  # depending on pgrep (Termux/proot blocks /proc/uptime → pgrep fails).
  local marker="claudecleanup_$$_$RANDOM"
  local fake="$tmp/$marker"
  cat > "$fake" <<EOF
#!/usr/bin/env bash
sleep 999 &
sleep 999 &
sleep 999 &
wait
EOF
  chmod +x "$fake"

  local tini setpriv
  tini=$(grep -oE '/nix/store/[^ ]*tini[^ ]*/bin/tini' "$CM" | head -1)
  setpriv=$(grep -oE '/nix/store/[^ ]*util-linux[^ ]*/bin/setpriv' "$CM" | head -1)
  [ -x "$tini" ]    || { rm -rf "$tmp"; return 1; }
  [ -x "$setpriv" ] || { rm -rf "$tmp"; return 1; }

  # Same shape as the deployed claude-malloc: synchronous foreground tini.
  # stdin redirected to /dev/null so tini skips tcsetpgrp() handoff
  # (irrelevant for the real interactive invocation).
  bash -c '"$1" --pdeathsig TERM "$2" -s -- "$3" </dev/null' _ "$setpriv" "$tini" "$fake" &
  local wpid=$!

  # Direct /proc scan: count processes whose cmdline contains the marker.
  count_marker() {
    local n=0 p
    for p in /proc/[0-9]*; do
      [ -r "$p/cmdline" ] || continue
      tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "$marker" && n=$((n+1)) || true
    done
    echo "$n"
  }

  sleep 2
  local before; before=$(count_marker)
  if [ "$before" -lt 1 ]; then
    kill "$wpid" 2>/dev/null || true
    rm -rf "$tmp"
    return 1
  fi

  kill -TERM "$wpid" 2>/dev/null || true
  sleep 3

  local after; after=$(count_marker)
  rm -rf "$tmp"
  [ "$after" = "0" ]
}
run "supervision reaps children on outer SIGTERM" test_supervision_kills_children

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
