#!/usr/bin/env bash
# Tester for patch 0056 — RSS folders reach full mail-folder parity, RSS account
# is editable, an Accounts shortcut tab is added, and background auto-update no
# longer dies silently.
#
# Static wiring assertions against the materialized mail-fairmail tracker.
# Usage: ./test-rss-folder-parity.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/ea_upstreams-sources/mail-fairmail/app/src/main/java/eu/faircode/email"
STRINGS="$ROOT/ea_upstreams-sources/mail-fairmail/app/src/main/res/values/strings_comms.xml"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
has() { grep -qF "$2" "$1" 2>/dev/null && ok "$3" || bad "$3"; }

echo "== T1: RSS folders get notify + navigation (parity defaults) =="
has "$SRC/CommsAccounts.java" "f.notify = true;"     "leaf folder notify=true at creation"
has "$SRC/CommsAccounts.java" "f.navigation = true;" "leaf folder navigation=true at creation"
has "$SRC/CommsAccounts.java" "rss.notify = true;"   "Feeds account notify=true"

echo "== T2: repairRssAccount upgrades EXISTING installs (pre-0056 data) =="
has "$SRC/CommsAccounts.java" "setFolderNotify(f.id, true)"     "repair sets notify on existing feed folders"
has "$SRC/CommsAccounts.java" "setFolderNavigation(f.id, true)" "repair sets navigation on existing feed folders"
has "$SRC/CommsAccounts.java" "setAccountNotify(rss.id, true)"  "repair sets account.notify"

echo "== T3: RSS account 'edit properties' opens the Cloud Feeds manager (was a no-op) =="
# the old bare 'return' immediately after the TYPE_RSS case must be gone
grep -Pzo 'case EntityAccount\.TYPE_RSS:[^\n]*\n\s*return;' "$SRC/ActivitySetup.java" >/dev/null 2>&1 \
    && bad "TYPE_RSS edit still an immediate no-op return" \
    || ok "TYPE_RSS edit no longer a bare return"
has "$SRC/ActivitySetup.java" 'new FragmentDialogCloudFeeds().show(getSupportFragmentManager(), "comms:cloud-feeds")' \
    "TYPE_RSS edit opens the Cloud Feeds dialog"

echo "== T4: Accounts shortcut tab inserted at index 1 (after Main, before Receive) =="
has "$SRC/FragmentOptions.java" "R.layout.fragment_accounts,"       "TAB_PAGES has accounts layout"
has "$SRC/FragmentOptions.java" "R.string.title_comms_accounts,"    "PAGE_TITLES has Accounts title"
has "$SRC/FragmentOptions.java" '"accounts",'                       "TAB_LABELS has accounts label"
has "$SRC/FragmentOptions.java" "return new FragmentAccounts();"    "getItem returns FragmentAccounts for the tab"
has "$STRINGS" 'name="title_comms_accounts"'                        "Accounts string defined"
# renumber sanity: About tab must now be case 13 (was 12)
has "$SRC/FragmentOptions.java" "case 13: // comms: Cloud Mail About tab"  "getItem switch renumbered (About=13)"

echo "== T5: background auto-update no longer dies silently (notification fallback) =="
has "$SRC/CommsInstallReceiver.java" "notifyConfirm(ctx, confirm)"        "receiver falls back to a notification"
has "$SRC/CommsInstallReceiver.java" "PendingIntent.getActivity"         "confirm wrapped as a PendingIntent (bg-launchable)"
has "$SRC/CommsInstallReceiver.java" "import androidx.core.app.NotificationCompat;" "NotificationCompat imported"

echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
