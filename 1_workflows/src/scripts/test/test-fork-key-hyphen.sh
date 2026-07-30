#!/usr/bin/env bash
# Regression test: fork keys containing a hyphen must resolve in the engine's
# jq lookups.
#
# Bug (GHA run 30528694044, ea_cloud-media-center): step_build_fork built its
# jq filters by shell-interpolating the fork key into a jq PATH:
#     jq -r ".forks.${key}.build.prepare // [] | .[]"
# With key="media-center" jq parses that as arithmetic on undefined functions:
#     jq: error: center/0 is not defined
# It never fired for mail/chat/dialer/matrix because those keys are single
# words. Fix: pass the key as data (--arg) and index with brackets.
#
# Pure shell + jq. No gradle, no SDK, no network.
set -uo pipefail

PASS=0
FAIL=0

check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf 'ok   %s\n' "$1"; PASS=$((PASS + 1))
  else
    printf 'FAIL %s\n       expected: %q\n       actual:   %q\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

cat >"$FIX/build.json" <<'JSON'
{
  "mode": "single-app",
  "forks": {
    "_doc": "underscore keys are metadata, not forks",
    "media-center": {
      "build": {
        "prepare": ["echo one", "echo two"],
        "gradle_props": {
          "_doc": "underscore keys must be skipped",
          "android.useAndroidX": "true",
          "org.gradle.jvmargs": "-Xmx4g"
        }
      }
    }
  }
}
JSON

key="media-center"

# --- the two expressions the engine actually uses (post-fix form) ------------
prepare=$(jq -r --arg k "$key" '.forks[$k].build.prepare // [] | .[]' "$FIX/build.json" | tr '\n' '|')
check "hyphenated key resolves build.prepare" "echo one|echo two|" "$prepare"

props=$(jq -r --arg k "$key" \
  '.forks[$k].build.gradle_props // {} | to_entries[] | select(.key | startswith("_") | not) | "\(.key)=\(.value)"' \
  "$FIX/build.json" | sort | tr '\n' '|')
check "hyphenated key resolves gradle_props, skips _doc" \
  "android.useAndroidX=true|org.gradle.jvmargs=-Xmx4g|" "$props"

# --- absent optional blocks must yield empty, not an error ------------------
missing=$(jq -r --arg k "nope" '.forks[$k].build.prepare // [] | .[]' "$FIX/build.json" 2>&1)
check "unknown key yields empty, no jq error" "" "$missing"

# --- the OLD form must genuinely fail, else this test proves nothing --------
if jq -r ".forks.${key}.build.prepare // [] | .[]" "$FIX/build.json" >/dev/null 2>&1; then
  check "old interpolated form is broken (guards against a vacuous test)" "fails" "succeeded"
else
  check "old interpolated form is broken (guards against a vacuous test)" "fails" "fails"
fi

# --- single-word keys must keep working (siblings mail/chat/dialer/matrix) --
cat >"$FIX/hub.json" <<'JSON'
{ "forks": { "mail": { "build": { "prepare": ["echo mail"] } } } }
JSON
sib=$(jq -r --arg k "mail" '.forks[$k].build.prepare // [] | .[]' "$FIX/hub.json")
check "single-word sibling key still resolves" "echo mail" "$sib"

# --- the engine source must not reintroduce an interpolated jq path ---------
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/cloud-comms-fork-engine.sh"
if [[ -f "$ENGINE" ]]; then
  # Count EXECUTABLE occurrences of an interpolated fork path. Comments and
  # human-readable error-message strings are excluded; a jq filter is not.
  #
  # An earlier version of this check only looked at two known call sites and a
  # bad regex reported "no others" while 29 remained (GHA 30529963919 failed
  # with the same jq error after the "fix"). It now scans the whole file.
  leaked=$(python3 - "$ENGINE" <<'PY'
import re, sys
bad = 0
for line in open(sys.argv[1], encoding='utf8'):
    s = line.strip()
    if s.startswith('#'):
        continue
    if '.forks.${' not in s:
        continue
    # errlog/printf/echo message text is prose, not a jq program
    if re.search(r'\b(errlog|log|printf|echo)\b', s):
        continue
    bad += 1
print(bad)
PY
)
  check "engine has no executable interpolated .forks.\${...} jq path" "0" "$leaked"

  # Every fork read must go through the safe helper.
  helper=$(python3 -c "
import sys; print(open(sys.argv[1],encoding='utf8').read().count('_fork_json'))" "$ENGINE")
  [[ "$helper" -gt 0 ]] \
    && check "engine defines/uses _fork_json helper" "yes" "yes" \
    || check "engine defines/uses _fork_json helper" "yes" "no"
else
  printf 'FAIL engine not found at %s\n' "$ENGINE"; FAIL=$((FAIL + 1))
fi

# --- ABI-keyed gradle task resolution -------------------------------------
# Upstream ReFra dimensions productFlavors by ABI, so each ABI has its OWN
# assemble task and one fixed string cannot serve a multi-ABI matrix. Gradle
# capitalizes only the first letter of a flavor name, so "arm64-v8a" becomes
# "Arm64-v8a" -- the hyphen SURVIVES. GHA run 30535280370 proved it:
#   Task 'assembleArm64V8aNoMLRelease' not found ...
#   Some candidates are: 'assembleArm64-v8aNoMLRelease'
cat >"$FIX/abi.json" <<'JSON'
{
  "forks": {
    "media-center": {
      "build": {
        "gradle_task": "assembleArm64-v8aNoMLRelease",
        "gradle_task_by_abi": {
          "arm64-v8a": "assembleArm64-v8aNoMLRelease",
          "x86_64": "assembleX86_64NoMLRelease"
        }
      }
    }
  },
  "single": { "build": { "gradle_task": "assembleGithubRelease" } }
}
JSON

resolve() { # resolve <abi> <json> — mirrors the engine's two-step lookup
  local abi="$1" f="$2" t
  t=$(jq -r --arg k media-center --arg a "$abi" \
      '.forks[$k].build.gradle_task_by_abi[$a] // empty' "$f")
  [[ -n "$t" ]] || t=$(jq -r --arg k media-center '.forks[$k].build.gradle_task // empty' "$f")
  printf '%s' "$t"
}

check "arm64-v8a resolves its own task (hyphen preserved)" \
  "assembleArm64-v8aNoMLRelease" "$(resolve arm64-v8a "$FIX/abi.json")"
check "x86_64 resolves a DIFFERENT task" \
  "assembleX86_64NoMLRelease" "$(resolve x86_64 "$FIX/abi.json")"
check "unknown ABI falls back to .gradle_task" \
  "assembleArm64-v8aNoMLRelease" "$(resolve riscv64 "$FIX/abi.json")"

# the wrong name that actually failed in CI must not be produced for any ABI
for a in arm64-v8a x86_64 riscv64; do
  got="$(resolve "$a" "$FIX/abi.json")"
  case "$got" in
    *Arm64V8a*) check "ABI $a does not emit the CI-proven-wrong Arm64V8a form" "clean" "GOT:$got" ;;
    *)          check "ABI $a does not emit the CI-proven-wrong Arm64V8a form" "clean" "clean" ;;
  esac
done

# a sibling fork declaring only .gradle_task must be unaffected by the new key
sib2=$(jq -r '.single.build.gradle_task_by_abi["arm64-v8a"] // .single.build.gradle_task' "$FIX/abi.json")
check "fork without gradle_task_by_abi still resolves .gradle_task" \
  "assembleGithubRelease" "$sib2"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
