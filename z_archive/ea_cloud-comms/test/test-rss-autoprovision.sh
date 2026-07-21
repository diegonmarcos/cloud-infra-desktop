#!/usr/bin/env bash
# Tester for the SUPER RSS READER auto-provision fix (patch 0055).
#
# BUG: the 142-channel RSS tree never appeared on its own — WorkerFeedSync
# .ensureChannelTree bailed when the `comms_cloud_base_url` pref was unset, and
# that pref was ONLY set by manually opening Configs → "Cloud feeds…" and typing
# our own infra URL. A user who added a raw RSS account saw nothing.
#
# FIX: bake COMMS_RSS_BASE (the wg0-only rss-gateway root) into BuildConfig and
# default ensureChannelTree to it, + fire WorkerFeedSync.oneShot on startup
# (init only schedules a 6h-delayed periodic). Tree now auto-provisions on
# first launch, data-driven, no manual step.
#
# Static source assertions + a LIVE check that the backend the app will hit is
# actually serving the taxonomy on the mesh.
#
# Usage: ./test-rss-autoprovision.sh   (run from anywhere; live check needs wg0)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"            # → ~/git/unix
SRC="$ROOT/ea_upstreams-sources/mail-fairmail/app/src/main/java/eu/faircode/email"
GRADLE="$ROOT/ea_upstreams-sources/mail-fairmail/app/build.gradle"
BJSON="$ROOT/ea_cloud-comms/build.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
has() { grep -qF "$2" "$1" 2>/dev/null && ok "$3" || bad "$3"; }

echo "== T1: default base URL is DATA-DRIVEN (build.json → gradle → BuildConfig) =="
python3 - "$BJSON" <<'PY' && ok "build.json declares COMMS_RSS_BASE gradle_prop" || bad "build.json missing COMMS_RSS_BASE"
import json,sys
d=json.load(open(sys.argv[1]))
gp=d["forks"]["mail"]["build"]["gradle_props"]
sys.exit(0 if gp.get("COMMS_RSS_BASE","").startswith("https://rss.") else 1)
PY
has "$GRADLE" 'buildConfigField "String", "COMMS_RSS_BASE"' "build.gradle bakes COMMS_RSS_BASE into BuildConfig"
# the doc key must be _-prefixed so build.sh jq (startswith _ | not) drops it
grep -q '"_COMMS_RSS_BASE_doc"' "$BJSON" && ok "doc key is _-prefixed (filtered from -P props)" || bad "doc key not _-prefixed"

echo "== T2: ensureChannelTree defaults to the baked base (no longer bails on unset) =="
has "$SRC/WorkerFeedSync.java" 'getString("comms_cloud_base_url", BuildConfig.COMMS_RSS_BASE)' \
    "ensureChannelTree defaults to BuildConfig.COMMS_RSS_BASE"
# guard: the old always-null default must be gone
grep -q 'getString("comms_cloud_base_url", null)' "$SRC/WorkerFeedSync.java" \
    && bad "old null-default still present (would still bail)" \
    || ok "old null-default removed"

echo "== T3: startup fires a one-shot (init only schedules a 6h-delayed periodic) =="
has "$SRC/ApplicationEx.java" "WorkerFeedSync.oneShot(this)" "ApplicationEx one-shots WorkerFeedSync on startup"

echo "== T4: Cloud Feeds dialog prefill is data-driven, not a hardcoded URL =="
has "$SRC/FragmentDialogCloudFeeds.java" 'getString(PREF_BASE,  BuildConfig.COMMS_RSS_BASE)' \
    "dialog prefill uses BuildConfig.COMMS_RSS_BASE"
grep -q 'getString(PREF_BASE,  "https://rss' "$SRC/FragmentDialogCloudFeeds.java" \
    && bad "dialog still hardcodes the infra URL" \
    || ok "dialog no longer hardcodes the infra URL"

echo "== T5: LIVE — the backend the app auto-provisions from is serving on the mesh =="
BASE="https://rss.diegonmarcos.com/feed"
if curl -s --max-time 12 "$BASE/health" | grep -q '"status"'; then
  ok "rss-gateway /feed/health reachable on wg0"
  CNT=$(curl -s --max-time 15 "$BASE/channels.json" | python3 -c "import json,sys; print(json.load(sys.stdin)['counts']['total'])" 2>/dev/null)
  [ -n "${CNT:-}" ] && [ "$CNT" -gt 50 ] 2>/dev/null \
    && ok "/feed/channels.json serves $CNT channels" \
    || bad "/feed/channels.json did not return a channel count"
else
  echo "  SKIP: rss.diegonmarcos.com unreachable (not on wg0 mesh right now) — static checks above still apply"
fi

echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
