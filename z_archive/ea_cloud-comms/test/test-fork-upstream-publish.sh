#!/usr/bin/env bash
# Tester for the upstream-APK → GHCR publish path (chat/matrix standalone
# images for the Constellation AppStore).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # ea_cloud-comms
BJ="$ROOT/build.json"; BS="$ROOT/build.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "== T1: build.sh parses cleanly =="
bash -n "$BS" && ok "bash -n build.sh" || bad "build.sh syntax error"

echo "== T2: build-fork has an upstream-APK branch (no gradle_task) =="
grep -q 'Upstream-APK fork (no gradle build)' "$BS" && ok "build-fork upstream-APK branch present" || bad "build-fork upstream branch missing"
grep -q '_fetch_upstream_apk "$key" "$up_url"' "$BS" && ok "build-fork reuses _fetch_upstream_apk (resign)" || bad "build-fork does not reuse _fetch_upstream_apk"
# the old hard-fail 'no build.gradle_task' must no longer abort upstream forks
grep -q 'neither build.gradle_task nor upstream_apk.url' "$BS" && ok "only fails when BOTH gradle_task and upstream_apk absent" || bad "missing combined guard"

echo "== T3: materialize-fork skips upstream-APK forks (no huge clone) =="
grep -q 'upstream-APK fork (no gradle build) — no source to materialize' "$BS" && ok "materialize early-returns for upstream forks" || bad "materialize does not skip upstream forks"

echo "== T4: matrix unblocked; both forks are upstream-APK with pinned sha =="
[ "$(jq -r '.forks.matrix.blocked_on' "$BJ")" = "null" ] && ok "matrix blocked_on cleared" || bad "matrix still blocked"
for k in chat matrix; do
  t=$(jq -r ".forks.$k.build.gradle_task" "$BJ")
  u=$(jq -r ".forks.$k.upstream_apk.url" "$BJ")
  s=$(jq -r ".forks.$k.upstream_apk.sha256" "$BJ")
  [ "$t" = "null" ] && [ -n "$u" ] && [ "$u" != "null" ] && [ ${#s} -eq 64 ] \
    && ok "$k: upstream-APK fork with pinned sha256" || bad "$k: missing gradle_task=null/url/sha"
  img=$(jq -r ".forks.$k.image" "$BJ")
  [ "$img" = "cloud-comms-$k" ] && ok "$k: GHCR image = $img" || bad "$k: unexpected image $img"
done

echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
