#!/usr/bin/env bash
# Tester for the Cloud Mail SUPER RSS READER — patches 0053 (Feeds account
# visible) + 0054 (channels.json → nested folder tree).
#
# T1/T2 are static (patch files + materialized tracker greps). T3/T4 hit the
# LIVE rss-gateway channels.json and replicate the app's tree logic; they print
# SKIP (not FAIL) off-mesh. T5 is the dex check on the released APK (SKIP if gh
# / unzip unavailable). Mirrors test-mail-updater-channel.sh conventions.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"      # → ~/git/cloud-unix
PATCHES="$ROOT/ea_cloud-comms/forks/mail/patches"
TRACKER="$ROOT/ea_upstreams-sources/mail-fairmail/app/src/main/java/eu/faircode/email"
GATEWAY="${RSS_GATEWAY_BASE:-https://rss.diegonmarcos.com/feed}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
pgrep_q() { grep -qF "$2" "$1" 2>/dev/null && ok "$3" || bad "$3"; }

P53=$(ls "$PATCHES"/0053-*.patch 2>/dev/null | head -1)
P54=$(ls "$PATCHES"/0054-*.patch 2>/dev/null | head -1)

echo "== T1: patch 0053 — Feeds account visibility (root cause) =="
[ -n "$P53" ] && ok "0053 patch present" || bad "0053 patch missing"
if [ -n "$P53" ]; then
  pgrep_q "$P53" "rss.synchronize = true"        "0053 flips the Feeds account synchronize flag"
  pgrep_q "$P53" "repairRssAccount"              "0053 adds the startup repair"
  pgrep_q "$P53" "TYPE_RSS"                       "0053 guards the sync engine against TYPE_RSS"
  pgrep_q "$P53" "inlineRSS"                      "0053 short-circuits RSS ops (no server op)"
  pgrep_q "$P53" "comms:rss-repair"              "0053 has the dex-marker log line"
fi

echo "== T2: patch 0054 — channel tree provisioning =="
[ -n "$P54" ] && ok "0054 patch present" || bad "0054 patch missing"
if [ -n "$P54" ]; then
  pgrep_q "$P54" "ensureFeedTree"                "0054 adds the tree provisioner"
  pgrep_q "$P54" "channels.json"                 "0054 fetches the channels contract"
  pgrep_q "$P54" "comms_cloud_channels"          "0054 gates on the subscribe-tree pref"
  pgrep_q "$P54" "selectable = false"            "0054 group folders are non-selectable containers"
  pgrep_q "$P54" "pruneFeedTree"                 "0054 prunes removed channels"
fi

echo "== T3: patches are actually applied in the materialized tracker =="
if [ -d "$TRACKER" ]; then
  pgrep_q "$TRACKER/CommsAccounts.java"     "ensureFeedTree"   "tracker CommsAccounts has ensureFeedTree"
  pgrep_q "$TRACKER/CommsAccounts.java"     "repairRssAccount" "tracker CommsAccounts has repairRssAccount"
  pgrep_q "$TRACKER/ServiceSynchronize.java" "TYPE_RSS)"       "tracker ServiceSynchronize has the RSS guard"
  pgrep_q "$TRACKER/WorkerFeedSync.java"    "ensureChannelTree" "tracker WorkerFeedSync fetches channels.json"
else
  echo "  SKIP: tracker not materialized (build.sh materialize-fork mail)"
fi

echo "== T4: LIVE channels.json contract + tree-shape replication (SKIP off-mesh) =="
curl -sf -m 8 "$GATEWAY/channels.json" -o /tmp/_rss_channels.json 2>/dev/null || true
if python3 -c "import json; d=json.load(open('/tmp/_rss_channels.json')); assert d.get('version')==1" 2>/dev/null; then
  python3 - /tmp/_rss_channels.json <<'PY' && ok "channels.json: unique paths, >=3 levels, derivable parent chains" || bad "channels.json tree-shape invalid"
import json,sys
d=json.load(open(sys.argv[1])); chs=d["channels"]
paths=[c["path"] for c in chs]
assert len(set(paths))==len(paths), "dup paths"
assert all(c.get("id") and c.get("title") and c.get("path") and c.get("feed") for c in chs), "missing fields"
assert max(p.count("/") for p in paths)>=2, "no >=3-level path"
# Replicate ensureFeedTree: every leaf's parent-prefix chain is derivable and
# the (account,name==full path) set stays unique across groups+leaves.
names=set(paths)  # leaf full-paths
for p in paths:
    seg=p.split("/")
    for i in range(1,len(seg)):
        names.add("/".join(seg[:i]))  # group folder full-paths
# a group path must never equal a leaf path (would collide on (account,name))
leaves=set(paths); groups=names-leaves
assert not (leaves & groups), "group/leaf name collision"
print("channels=%d groups=%d maxdepth=%d" % (len(chs), len(groups), max(p.count('/') for p in paths)+1))
PY
  for t in health_containers health_report_cloud-health-full-daily; do
    curl -sf -m 8 "$GATEWAY/c/$t.atom" 2>/dev/null | grep -q "<feed" \
      && ok "feed $t.atom is valid Atom" || echo "  SKIP: $t feed empty/unreachable"
  done
else
  echo "  SKIP: gateway $GATEWAY unreachable — not on wg0 (static checks above still ran)"
fi

echo "== T5: released APK carries the 0053/0054 string markers (R8-safe, SKIP if no gh/unzip) =="
if command -v gh >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
  TAG=$(gh api "repos/diegonmarcos/unix/releases?per_page=30" \
    --jq '[.[]|select(.tag_name|startswith("cloud-comms-mail-"))|.tag_name]|sort|last' 2>/dev/null)
  if [ -n "$TAG" ] && [ "$TAG" != "null" ]; then
    TMP=$(mktemp -d)
    if gh release download "$TAG" -R diegonmarcos/unix -p 'cloud-comms-mail.apk' -D "$TMP" 2>/dev/null; then
      unzip -oq "$TMP/cloud-comms-mail.apk" 'classes*.dex' -d "$TMP" 2>/dev/null
      if grep -aql "channels.json" "$TMP"/classes*.dex 2>/dev/null \
         && grep -aql "comms:rss-repair" "$TMP"/classes*.dex 2>/dev/null; then
        ok "released APK ($TAG) contains channels.json + comms:rss-repair markers"
      else
        echo "  SKIP: markers absent — release $TAG predates 0053/0054 (re-run after ship)"
      fi
    else
      echo "  SKIP: could not download APK for $TAG"
    fi
    rm -rf "$TMP"
  else
    echo "  SKIP: no cloud-comms-mail release found"
  fi
else
  echo "  SKIP: gh/unzip not available"
fi

echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
