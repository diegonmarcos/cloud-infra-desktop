#!/usr/bin/env bash
# #883 D2 tester: the commit-msg hook is ADVISORY. With a stub `jev-gate` on PATH it must
#  - always exit 0 (every kind of no opinion = silence, a confident adverse answer = one stderr line),
#  - never call jev-gate for a staged vault/secret path, an empty or merge message, or with JEV_COMMIT_MSG=0,
#  - and do nothing when jev-gate is not installed.
# Run: bash 0_git/test/test-commit-msg.sh
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/src/hooks/commit-msg"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
check() { if [ "$2" != "$3" ]; then echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

mkdir -p "$T/bin" "$T/repo"
cat > "$T/bin/jev-gate" <<'STUB'
#!/bin/sh
use=""; [ "$1" = decide ] && [ "$2" = --use ] && use="$3"
echo "$use" >> "$STUB_CALLS"
cat > /dev/null
case "$use" in
  desktop_commit_msg) printf '%s' "$STUB_MATCH" ;;
  desktop_secret_miss) printf '%s' "$STUB_SECRET" ;;
esac
STUB
chmod +x "$T/bin/jev-gate"
cd "$T/repo" && git init -q . && git config user.email a@b && git config user.name t
echo hi > a.txt && git add a.txt
export STUB_CALLS="$T/calls"

ans() { printf '{"ok":true,"results":{"%s":{"type":"noul","value":%s,"p":0.95,"confident":%s}}}' "$1" "$2" "$3"; }
run() {  # $1 = message, prints stderr; sets RC
  printf '%s\n' "$1" > "$T/msg"; : > "$T/calls"
  OUT=$(PATH="$T/bin:$PATH" bash "$HOOK" "$T/msg" 2>&1 >/dev/null); RC=$?
}

STUB_MATCH="$(ans matches true true)" STUB_SECRET="$(ans secret false true)" run "add a note"
check "confident agreement: silent, exit 0" "$OUT|$RC" "|0"
check "both questions asked" "$(sort "$T/calls" | tr '\n' ' ')" "desktop_commit_msg desktop_secret_miss "

STUB_MATCH="$(ans matches false true)" STUB_SECRET="$(ans secret false true)" run "unrelated words"
case "$OUT" in *"may not describe"*) ;; *) echo "FAIL mismatch warning missing"; fail=1 ;; esac
check "a warning never blocks" "$RC" "0"

STUB_MATCH="$(ans matches true true)" STUB_SECRET="$(ans secret true true)" run "add a note"
case "$OUT" in *"may contain a secret"*) ;; *) echo "FAIL secret warning missing"; fail=1 ;; esac
check "secret warning exit" "$RC" "0"

STUB_MATCH="$(ans matches false false)" STUB_SECRET="$(ans secret true false)" run "x"
check "unsure is silence" "$OUT|$RC" "|0"
for bad in '' '<html>' '{"ok":false,"reason":"no_key"}' '{"ok":false,"reason":"gate_closed","call":"c"}'; do
  STUB_MATCH="$bad" STUB_SECRET="$bad" run "x"
  check "no opinion ($bad) is silence" "$OUT|$RC" "|0"
done

run ""; check "empty message: no call" "$(wc -l < "$T/calls" | tr -d ' ')" "0"
run "Merge branch main"; check "merge message: no call" "$(wc -l < "$T/calls" | tr -d ' ')" "0"
JEV_COMMIT_MSG=0 run "x"; check "JEV_COMMIT_MSG=0: no call" "$(wc -l < "$T/calls" | tr -d ' ')" "0"

for f in secrets.yaml .env deploy.pem cloud-vault/x.txt key.age; do
  mkdir -p "$(dirname "$f")"; echo s > "$f"; git add -f "$f"
  STUB_MATCH="$(ans matches false true)" STUB_SECRET="$(ans secret true true)" run "x"
  check "staged $f: no call, no output" "$(wc -l < "$T/calls" | tr -d ' ')|$OUT|$RC" "0||0"
  git reset -q "$f"
done

printf 'x\n' > "$T/msg"; OUT=$(PATH="/usr/bin:/bin" bash "$HOOK" "$T/msg" 2>&1); check "no jev-gate installed: silent, exit 0" "$OUT|$?" "|0"
[ $fail = 0 ] && echo PASS || { echo FAILED; exit 1; }
