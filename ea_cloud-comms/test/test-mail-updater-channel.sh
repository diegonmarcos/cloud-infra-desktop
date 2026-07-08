#!/usr/bin/env bash
# Tester for the Cloud Mail in-app update channel (patch 0045 stamp + patch 0046
# release resolution). Runs against the LIVE GitHub API and the LIVE released
# APK — no mocks. Every assertion mirrors the exact Java logic in
# CommsUpdateWorker.fetchLatestRelease() / the doWork() stamp comparison.
#
# Usage: ./test-mail-updater-channel.sh
# Exit 0 = channel proven end-to-end. Any FAIL = exit 1.
set -u
OWNER=diegonmarcos REPO=unix ASSET=cloud-comms-mail.apk
PREFIX="cloud-comms-mail-"   # = COMMS_RELEASE_ASSET_NAME.replace(".apk","") + "-"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "== T1: the trap — /releases/latest does NOT belong to mail (this is what broke the installed app)"
LATEST_TAG=$(gh api "repos/$OWNER/$REPO/releases/latest" --jq .tag_name)
echo "  /releases/latest = $LATEST_TAG"
case "$LATEST_TAG" in
  "$PREFIX"*) bad "repo Latest badge is a mail release — trap condition gone, T2 no longer tests the fix under real conditions" ;;
  *)          ok  "repo Latest badge held by another artifact — old /releases/latest code WOULD fail here; new code must not use it" ;;
esac

echo "== T2: replicate patch-0046 fetchLatestRelease() against live API"
# Java: list /releases?per_page=30, keep tags starting with PREFIX, stamp = after
# last '-', keep highest stamp that carries the ASSET.
RESOLVED=$(gh api "repos/$OWNER/$REPO/releases?per_page=30" --jq "
  [.[] | select(.tag_name | startswith(\"$PREFIX\"))
       | select([.assets[].name] | index(\"$ASSET\"))
       | {tag: .tag_name, stamp: (.tag_name | split(\"-\") | last),
          url: (.assets[] | select(.name==\"$ASSET\") | .browser_download_url)}]
  | max_by(.stamp)")
TAG=$(jq -r .tag <<<"$RESOLVED"); STAMP=$(jq -r .stamp <<<"$RESOLVED"); URL=$(jq -r .url <<<"$RESOLVED")
echo "  resolved: $TAG (stamp $STAMP)"
[ -n "$TAG" ] && [ "$TAG" != "null" ] && ok "algorithm resolves a mail release despite the contended Latest badge" || bad "algorithm resolved nothing"
[[ "$STAMP" =~ ^[0-9]{8}\.[0-9]{6}$ ]] && ok "stamp is YYYYMMDD.HHMMSS ($STAMP)" || bad "stamp malformed: $STAMP"

echo "== T3: assetless releases (2026-07-07 bare-release era) must NOT win"
NEWEST_ANY=$(gh api "repos/$OWNER/$REPO/releases?per_page=30" --jq "
  [.[] | select(.tag_name | startswith(\"$PREFIX\")) | .tag_name] | max")
if [ "$NEWEST_ANY" = "$TAG" ]; then
  ok "newest mail tag carries the APK asset"
else
  # newer tag exists without asset — algorithm must have skipped it
  gh api "repos/$OWNER/$REPO/releases/tags/$NEWEST_ANY" --jq '[.assets[].name]' | grep -q "$ASSET" \
    && bad "resolver picked $TAG but $NEWEST_ANY has the asset too" \
    || ok  "assetless newer tag $NEWEST_ANY correctly skipped"
fi

echo "== T4: update-decision logic (exact Java comparisons, lexicographic compareTo)"
decide() { # installed stamp -> UP_TO_DATE | UPDATE
  local inst=$1
  if [ "$inst" = "dev" ] || [ "$inst" = "$STAMP" ] || [[ "$STAMP" < "$inst" ]]; then echo UP_TO_DATE; else echo UPDATE; fi
}
[ "$(decide dev)"              = UP_TO_DATE ] && ok "installed=dev → up-to-date (why pre-0045 builds are update-blind)" || bad "dev guard broken"
[ "$(decide "$STAMP")"         = UP_TO_DATE ] && ok "installed==release stamp → up to date (no self-update loop)"       || bad "self-compare broken"
[ "$(decide 20260707.000000)"  = UPDATE     ] && ok "older installed stamp → update detected"                            || bad "older stamp not detected"
[ "$(decide 20270101.000000)"  = UP_TO_DATE ] && ok "newer installed stamp → up to date"                                 || bad "newer stamp treated as update"

echo "== T5: the released APK itself — download + prove it contains stamp + patch-0046 code"
TMP=$(mktemp -d)
curl -sfL -o "$TMP/app.apk" "$URL" || bad "APK download failed: $URL"
SIZE=$(stat -c%s "$TMP/app.apk" 2>/dev/null || echo 0)
[ "$SIZE" -gt 10000000 ] && ok "APK downloaded, $((SIZE/1024/1024)) MB" || bad "APK too small: $SIZE bytes"
head -c2 "$TMP/app.apk" | grep -q PK && ok "APK zip magic OK" || bad "not a zip"
unzip -o -q "$TMP/app.apk" 'classes*.dex' -d "$TMP" 2>/dev/null
if grep -aql "$STAMP" "$TMP"/classes*.dex 2>/dev/null; then
  ok "baked COMMS_BUILD_TIMESTAMP=$STAMP found in dex (NOT 'dev' — updater alive)"
else
  bad "stamp $STAMP not found in dex — APK/release stamp mismatch"
fi
grep -aql "no release with tag prefix" "$TMP"/classes*.dex 2>/dev/null \
  && ok "patch-0046 code present in dex (prefix-filtered release listing)" \
  || bad "patch-0046 marker string absent from dex — old fetch code shipped"
grep -aql "releases/latest" "$TMP"/classes*.dex 2>/dev/null \
  && echo "  note: 'releases/latest' string still in dex (may be unrelated FairEmail code)" \
  || ok "no 'releases/latest' string anywhere in dex — old endpoint fully gone"
rm -rf "$TMP"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
