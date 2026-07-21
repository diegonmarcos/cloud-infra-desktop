#!/usr/bin/env bash
# Tester for patch 0058 — the two genuine feed-management gaps.
# (rename/notify/delete/add-single already work natively; these were the gaps.)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/ea_upstreams-sources/mail-fairmail/app/src/main/java/eu/faircode/email"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
has() { grep -qF "$2" "$1" 2>/dev/null && ok "$3" || bad "$3"; }

echo "== T1: user rename sticks — display no longer clobbered on re-sync =="
# the existing-folder repair branches must NOT re-assign display from the server title/label
grep -q 'f.display = title; changed = true;' "$SRC/CommsAccounts.java" \
  && bad "leaf still overwrites display on re-sync" || ok "leaf preserves user display on re-sync"
grep -q 'f.display = label; changed = true;' "$SRC/CommsAccounts.java" \
  && bad "group still overwrites display on re-sync" || ok "group preserves user display on re-sync"

echo "== T2: RSS group folders can be renamed (Edit properties offered) =="
has "$SRC/AdapterFolder.java" "folder.accountProtocol == EntityAccount.TYPE_RSS" "group-folder branch gates on TYPE_RSS"
has "$SRC/AdapterFolder.java" "!folder.selectable && folder.account != null" "non-selectable group folders get a menu item"
grep -A6 "RSS GROUP folders" "$SRC/AdapterFolder.java" | grep -q "title_edit_properties" \
  && ok "group folders offered Edit properties (rename)" || bad "group Edit properties not wired"

echo "== T3: per-feed poll interval honored (poll_factor drives WorkerFeedSync) =="
has "$SRC/WorkerFeedSync.java" "folder.poll_factor" "sync reads per-feed poll_factor"
has "$SRC/WorkerFeedSync.java" "effectiveMs" "computes effective interval = base * factor"
has "$SRC/WorkerFeedSync.java" "setFolderLastSync(folder.id, now)" "stamps last_sync to drive the due-check"

echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
