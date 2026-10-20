#!/usr/bin/env bash
# #883 D1 tester: the desktop Claude settings register the Jev gate as a hook, and "no gate" is "no opinion".
#  - PermissionRequest (Bash|Edit|Write) and UserPromptSubmit both call `jev-gate claude`,
#  - each command is guarded: with no jev-gate on PATH it exits 0 and prints NOTHING,
#  - nothing in the registration can deny (no PreToolUse, no blocking exit code, no `deny` rule added),
#  - the three committed copies (src SoT, dist, project .claude) are identical.
# Run: bash 0_apps/test/test-claude-jev-hooks.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/0_apps/src/claude/settings.json"
fail=0
check() { if [ "$2" != "$3" ]; then echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
q() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$S" "$1"; }

check "PermissionRequest matcher" "$(q 'd["hooks"]["PermissionRequest"][0]["matcher"]')" "Bash|Edit|Write"
check "only the two events" "$(q 'sorted(d["hooks"])')" "['PermissionRequest', 'UserPromptSubmit']"
check "no deny rule added" "$(q 'd["permissions"]["deny"]')" "[]"
for ev in PermissionRequest UserPromptSubmit; do
  cmd="$(q "d['hooks']['$ev'][0]['hooks'][0]['command']")"
  case "$cmd" in *"exec jev-gate claude") ;; *) echo "FAIL $ev command is not 'jev-gate claude': $cmd"; fail=1 ;; esac
  out="$(PATH=/usr/bin:/bin sh -c "$cmd" </dev/null 2>&1)"; rc=$?
  check "$ev without jev-gate: no output, exit 0" "$out|$rc" "|0"
  tmo="$(q "d['hooks']['$ev'][0]['hooks'][0]['timeout']")"
  [ "$tmo" -ge 12 ] || { echo "FAIL $ev timeout $tmo below the gate's own 6 s call + margin"; fail=1; }
  # with a stub gate on PATH the command really runs it
  mkdir -p "$(dirname "$0")/.stub" && printf '#!/bin/sh\necho ran-$1\n' > "$(dirname "$0")/.stub/jev-gate" && chmod +x "$(dirname "$0")/.stub/jev-gate"
  out="$(PATH="$(cd "$(dirname "$0")/.stub" && pwd):/usr/bin:/bin" sh -c "$cmd" </dev/null 2>&1)"
  check "$ev with jev-gate: it runs" "$out" "ran-claude"
  rm -rf "$(dirname "$0")/.stub"
done
for c in 0_apps/dist/dotfiles/claude/settings.json .claude/settings.json; do
  cmp -s "$S" "$ROOT/$c" || { echo "FAIL $c differs from the SoT"; fail=1; }
done
[ $fail = 0 ] && echo PASS || { echo FAILED; exit 1; }
