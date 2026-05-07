#!/usr/bin/env bash
# test-no-stale-result.sh — guard against the result-symlink-in-src bug
#
# Bug history (2026-04-17 → 2026-05-06):
#   `nix build` (without --no-link) creates ./result as a symlink to
#   /nix/store/<hash>-builders-dist. If this symlink got committed (via
#   `git add -f` bypassing gitignore), every subsequent `bash build.sh
#   build` would `cp -rL src/* dist/`, dereference the OLD symlink, and
#   drag stale closure bytes into dist/result/ — masking source edits.
#   Symptom: ship-hm.sh content edits invisible until manual cleanup.
#
# Engine fix (build.sh): cp loop now skips `result` and `result-*`.
# Hygiene fix (.gitignore): tracks `src/result*` and root `result*`.
# This test enforces both.
#
# Run:  bash cb_containers-builders/src/test-no-stale-result.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
ok()   { printf "  \xe2\x9c\x93 %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \xe2\x9c\x97 %s\n" "$1" >&2; FAIL=$((FAIL+1)); }

echo "=== test-no-stale-result ==="

# Test 1: src/result is NOT tracked in git
if git -C "$ROOT/.." ls-files --error-unmatch \
       "cb_containers-builders/src/result" >/dev/null 2>&1; then
    fail "src/result is git-tracked — must be untracked (git rm --cached) and gitignored"
else
    ok  "src/result is not git-tracked"
fi

# Test 2: .gitignore covers result symlinks
if grep -qE '^src/result\b' "$ROOT/.gitignore" 2>/dev/null; then
    ok  ".gitignore has 'src/result' entry"
else
    fail ".gitignore missing 'src/result' entry"
fi
if grep -qE '^result\b' "$ROOT/.gitignore" 2>/dev/null; then
    ok  ".gitignore has root 'result' entry"
else
    fail ".gitignore missing root 'result' entry"
fi

# Test 3: build.sh cp loop skips result (engine fix)
if grep -qE 'result\|result-\*' "$ROOT/build.sh" 2>/dev/null; then
    ok  "build.sh skips result/result-* in cp loop"
else
    fail "build.sh missing the cp-loop result skip — `cp -rL src/* dist/` would deref a stale symlink"
fi

echo
printf "  pass: %d\n  fail: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "  all good — stale-result regression cannot recur"
