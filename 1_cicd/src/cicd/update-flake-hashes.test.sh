#!/usr/bin/env bash
# ============================================================================
# update-flake-hashes.test.sh — pin-coverage tester
# ----------------------------------------------------------------------------
# WHAT THIS EXISTS TO CATCH
#
# On 2026-09-09 every nix-on-droid closure build was red with
#
#   error: hash mismatch in fixed-output derivation '...my-webserver-aarch64.drv'
#     specified: sha256-8hjxYzs1mxPItIyYe7OQwVo98mKqRJmhF9Wi/aWOK5g=
#          got:  sha256-UVMz0XfpcI63qLtavRWNSCPEGwRmcsM64kFJeectm2c=
#
# while update-flake-hashes.yml ran green and pushed nothing. It was not a
# stale value. my-webserver's pin had MOVED -- out of this repo's two
# hashes.json files and into cloud-u-linux's, reached through a flake input --
# and the updater kept faithfully rewriting the two files it had always
# rewritten, which by then nothing read. Both pieces of automation were
# behaving; they were describing different pins. home-manager-files is
# downstream of that fetch, so the entire closure failed and the phone, which
# installs a built closure and cannot build, received nothing for six days.
#
# So the invariant is not "the hashes are current" -- CI proves that. It is
# that EVERY pin the flakes read is maintained by something, and every pin the
# updater maintains is read. A pin with no updater goes stale; an updater with
# no reader is green forever while the build is red. Both directions failed
# here, in that order.
#
# Runs offline. Never invokes nix: the discovery loop is lifted out of the
# workflow itself and run against a stubbed `nix`, so what is tested is the
# shipped code and not a paraphrase of it that can drift away from it.
# ============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR" && while [ "$PWD" != "/" ] && [ ! -e "$PWD/.git" ]; do cd ..; done; pwd)"
WORKFLOW="$DIR/update-flake-hashes.yml"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
nope() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "▶ update-flake-hashes pin-coverage tester  ($WORKFLOW)"

[ -f "$WORKFLOW" ] || { nope "workflow missing"; exit 1; }
for dep in jq python3; do
  command -v "$dep" >/dev/null 2>&1 || { echo "  $dep required"; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "  python3 PyYAML required"; exit 1; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# ---------------------------------------------------------------------------
# Phase 1 · the flake-input pins: does the updater reach every consumer?
#
# The generalised form of "it only refreshed one architecture". Any worklist
# the updater does not derive from the repo is a worklist that can silently
# omit a flake, an input, or an arch. So: run the real discovery loop with a
# stubbed nix and check what it would have updated against an independent
# enumeration of the locks.
# ---------------------------------------------------------------------------
echo "▶ Phase 1 · flake-input pins (cloud-u-linux artifacts reached by flake.lock)"

# Lift the step's script out of the workflow by its step name -- not by line
# number, which drifts, and not by a copy pasted here, which is the exact
# two-opinions-about-one-thing bug this whole file is about.
python3 - "$WORKFLOW" > "$SANDBOX/discover.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = wf["jobs"]["update"]["steps"]
want = "Bump every cloud-u-linux flake input"
for s in steps:
    if s.get("name") == want:
        sys.stdout.write(s["run"])
        break
else:
    sys.exit(f"no step named {want!r}")
PY
[ -s "$SANDBOX/discover.sh" ] && ok "discovery step lifted from the workflow" \
  || nope "discovery step lifted from the workflow"
bash -n "$SANDBOX/discover.sh" && ok "discovery step is valid bash" \
  || nope "discovery step is valid bash"

# Stub nix. It only records its arguments: the loop must be exercised for real,
# but nothing may fetch, evaluate or rewrite a lock on a developer's machine.
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/nix" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$SANDBOX/nix-calls"
STUB
chmod +x "$SANDBOX/bin/nix"
: > "$SANDBOX/nix-calls"

( cd "$REPO_ROOT" && PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/discover.sh" ) \
  > "$SANDBOX/discover.out" 2>&1
if [ $? -eq 0 ]; then ok "discovery step runs clean over the real repo"
else nope "discovery step runs clean over the real repo: $(tail -3 "$SANDBOX/discover.out")"; fi

# Independent enumeration: every root-level flake input resolved from
# cloud-u-linux with a subdirectory, in every tracked lock. Deliberately not
# sharing code with the workflow -- an oracle that reuses the implementation
# agrees with its own bugs.
( cd "$REPO_ROOT" && git ls-files '*flake.lock' ) | while read -r lock; do
  python3 - "$REPO_ROOT/$lock" "$(dirname "$lock")" <<'PY'
import json, sys, os
lock, flake = sys.argv[1], sys.argv[2]
d = json.load(open(lock))
nodes, root = d["nodes"], d["root"]
for name, key in nodes[root].get("inputs", {}).items():
    if isinstance(key, list):
        continue
    orig = nodes.get(key, {}).get("original", {})
    if orig.get("repo") == "cloud-u-linux" and orig.get("dir"):
        print(f"{flake}\t{name}")
PY
done | sort > "$SANDBOX/expected"

# What the loop would actually have updated, normalised the same way.
sed -n 's/^flake update \(.*\) --flake path:\(.*\)$/\2\t\1/p' "$SANDBOX/nix-calls" \
  | while IFS="$(printf '\t')" read -r flakepath names; do
      for n in $names; do printf '%s\t%s\n' "${flakepath#"$REPO_ROOT"/}" "$n"; done
    done | sort > "$SANDBOX/actual"

expected_n=$(wc -l < "$SANDBOX/expected")
if [ "$expected_n" -gt 0 ]; then
  ok "the repo declares cloud-u-linux flake inputs to maintain ($expected_n)"
else
  nope "no cloud-u-linux flake inputs found -- the oracle itself is broken"
fi

missed="$(comm -23 "$SANDBOX/expected" "$SANDBOX/actual" | tr '\t' ':' | tr '\n' ' ')"
if [ -z "$missed" ]; then
  ok "every cloud-u-linux flake input is updated (none skipped)"
else
  nope "flake inputs the updater never bumps: $missed"
fi

extra="$(comm -13 "$SANDBOX/expected" "$SANDBOX/actual" | tr '\t' ':' | tr '\n' ' ')"
if [ -z "$extra" ]; then
  ok "the updater bumps nothing that is not a declared input"
else
  nope "updater bumps inputs no lock declares: $extra"
fi

# The lock is the pin for these, so it must be in what gets committed.
if grep -q "git ls-files '\*/src/flake.lock'" "$WORKFLOW" \
   || grep -q "git ls-files '\*flake.lock'" "$WORKFLOW"; then
  ok "the bumped flake.lock files are staged for commit"
else
  nope "the bumped flake.lock files are staged for commit"
fi

# ---------------------------------------------------------------------------
# Phase 2 · the in-repo pins: no dead file, no unmaintained file.
#
# Two directions, and the 2026-09-09 outage needed both to be wrong. A pin file
# the updater writes but no .nix reads makes the updater green while the build
# is red. A pin file a .nix reads but no updater writes goes stale the first
# time the artifact is republished.
# ---------------------------------------------------------------------------
echo "▶ Phase 2 · in-repo pin files (fetchurl hashes committed here)"

# Read by nix: any hashes json a .nix pulls in with readFile.
( cd "$REPO_ROOT" && git ls-files '*.nix' ) | while read -r f; do
  grep -o 'readFile \./[A-Za-z0-9._/-]*\.json' "$REPO_ROOT/$f" 2>/dev/null \
    | sed 's|readFile \./||' \
    | while read -r rel; do
        printf '%s\n' "$(cd "$REPO_ROOT/$(dirname "$f")" && realpath -m --relative-to="$REPO_ROOT" "$rel")"
      done
done | grep -i 'hash' | sort -u > "$SANDBOX/read-by-nix"

# Written by the updater: any path it redirects into or hands to jq.
grep -oE '> [A-Za-z0-9._/-]*hashes[A-Za-z0-9._/-]*\.json' "$WORKFLOW" \
  | sed 's/^> //' | sort -u > "$SANDBOX/written-by-updater"

read_n=$(wc -l < "$SANDBOX/read-by-nix")
if [ "$read_n" -gt 0 ]; then
  ok "the flakes read in-repo pin files ($read_n)"
else
  nope "no in-repo pin file found -- the oracle itself is broken"
fi

unmaintained="$(comm -23 "$SANDBOX/read-by-nix" "$SANDBOX/written-by-updater" | tr '\n' ' ')"
if [ -z "$unmaintained" ]; then
  ok "every pin file a flake reads is written by the updater"
else
  nope "pin files read by a flake but maintained by nothing: $unmaintained"
fi

dead="$(comm -13 "$SANDBOX/read-by-nix" "$SANDBOX/written-by-updater" | tr '\n' ' ')"
if [ -z "$dead" ]; then
  ok "every pin file the updater writes is read by a flake"
else
  nope "pin files the updater writes that no flake reads: $dead"
fi

# The same thing from the other end: a committed hashes.json nobody reads is
# dead weight that a future updater will be tempted to keep current.
orphans=""
for h in $( cd "$REPO_ROOT" && git ls-files '*hashes*.json' ); do
  grep -qx "$h" "$SANDBOX/read-by-nix" || orphans="$orphans $h"
done
if [ -z "$orphans" ]; then
  ok "no orphaned hashes.json is committed"
else
  nope "committed hashes.json that no .nix reads:$orphans"
fi

# ---------------------------------------------------------------------------
# Phase 3 · rolling release tags.
#
# A fixed-output derivation pins a hash, which is a promise that the bytes at
# that URL never change. A rolling tag breaks that promise on every publish. It
# is survivable ONLY while something re-pins the hash after each one -- and
# that is exactly the guarantee my-webserver lost when its pin left this repo.
# ---------------------------------------------------------------------------
echo "▶ Phase 3 · rolling release tags"

rolling=0; unpinned=""
while read -r f; do
  grep -q -- '-latest' "$REPO_ROOT/$f" || continue
  grep -q 'fetchurl' "$REPO_ROOT/$f" || continue
  rolling=$((rolling + 1))
  # This file fetches through a rolling tag, so the pin file it reads must be
  # one the updater rewrites on every tick.
  its_pins="$(grep -o 'readFile \./[A-Za-z0-9._/-]*\.json' "$REPO_ROOT/$f" | sed 's|readFile \./||')"
  covered=0
  for rel in $its_pins; do
    abs="$(cd "$REPO_ROOT/$(dirname "$f")" && realpath -m --relative-to="$REPO_ROOT" "$rel")"
    grep -qx "$abs" "$SANDBOX/written-by-updater" && covered=1
  done
  [ "$covered" = 1 ] || unpinned="$unpinned $f"
done < <( cd "$REPO_ROOT" && git ls-files '*.nix' )

ok "rolling-tag fetches inventoried ($rolling)"
if [ -z "$unpinned" ]; then
  ok "every rolling-tag fetch has its hash re-pinned by the updater"
else
  nope "rolling-tag fetches with no updater re-pinning them:$unpinned"
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
