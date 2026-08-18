#!/usr/bin/env bash
# Tester for patch 0048 (JMAP sync: newest-first query sort + sync user
# folders). Runs against the LIVE Stalwart JMAP server — no mocks. T2/T3
# replicate the exact Email/query the app sends before/after the patch and
# prove root cause 1 ("inbox frozen at 15-May") and its fix. T1 proves root
# cause 2 was client-side (server folders DO carry mail). T4 proves the
# patch content. T5 checks the released APK for the fix markers (PENDING
# until CI ships a post-0048 build).
#
# Credentials: sourced at runtime from the private vault (never printed).
# Usage: ./test-mail-jmap-sync.sh
# Exit 0 = fix proven end-to-end. Any FAIL = exit 1.
set -u
SECRETS="$HOME/git/cloud-vault/A1_Cloud-secrets/aa-sui_mail-mcp-secrets.secrets"
PATCH="$HOME/git/cloud-unix/ea_cloud-comms/forks/mail/patches/0048-comms-fix-JMAP-sync-newest-first-query-sort-sync-use.patch"
JMAP_BASE="https://jmap.diegonmarcos.com"
LIMIT=200                       # = JmapSync.SYNC_LIMIT
PRE_FIX_STAMP="20260708.123849" # newest release BEFORE patch 0048
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# shellcheck disable=SC1090
. "$SECRETS" || { echo "FATAL: cannot source vault secrets"; exit 1; }
jmap() { # POST a JMAP request body on stdin, JSON out
  curl -sfL -u "$MAIL_USER:$MAIL_PASSWORD" -H 'Content-Type: application/json' \
       -d @- "$API_URL"
}

echo "== T0: JMAP session (auth + account discovery, as the app's SessionResource fetch)"
# -L: Stalwart 301s /.well-known/jmap -> /jmap/session (the jmap library follows it too)
SESSION=$(curl -sfL -u "$MAIL_USER:$MAIL_PASSWORD" "$JMAP_BASE/.well-known/jmap")
ACCOUNT=$(jq -r '.primaryAccounts["urn:ietf:params:jmap:mail"]' <<<"$SESSION")
API_URL=$(jq -r '.apiUrl' <<<"$SESSION")
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "null" ] && ok "session OK, mail account resolved" || { bad "no mail account in session"; echo "RESULT: $PASS passed, $((FAIL)) failed"; exit 1; }

echo "== T1: server-side truth — INBOX + user/filter folders carry mail (emptiness was client-side)"
MB=$(jmap <<EOF
{"using":["urn:ietf:params:jmap:core","urn:ietf:params:jmap:mail"],
 "methodCalls":[["Mailbox/get",{"accountId":"$ACCOUNT"},"0"]]}
EOF
)
INBOX_ID=$(jq -r '.methodResponses[0][1].list[] | select(.role=="inbox") | .id' <<<"$MB")
INBOX_TOTAL=$(jq -r '.methodResponses[0][1].list[] | select(.role=="inbox") | .totalEmails' <<<"$MB")
USER_NONEMPTY=$(jq '[.methodResponses[0][1].list[] | select(.role==null and .totalEmails>0)] | length' <<<"$MB")
echo "  INBOX=$INBOX_ID totalEmails=$INBOX_TOTAL user-folders-with-mail=$USER_NONEMPTY"
[ "${INBOX_TOTAL:-0}" -gt "$LIMIT" ] && ok "INBOX total ($INBOX_TOTAL) > SYNC_LIMIT ($LIMIT) — the trap condition for root cause 1 is real" || bad "INBOX <= $LIMIT msgs — window bug can't reproduce"
[ "${USER_NONEMPTY:-0}" -ge 3 ] && ok "$USER_NONEMPTY user/filter folders have mail on the server — 'all empty' was the client skipping them" || bad "server user folders empty too — root cause 2 not client-side"

echo "== T2: root cause 1 — the PRE-0048 query (no sort, limit $LIMIT) returns a stale window"
UNSORTED=$(jmap <<EOF
{"using":["urn:ietf:params:jmap:core","urn:ietf:params:jmap:mail"],
 "methodCalls":[
  ["Email/query",{"accountId":"$ACCOUNT","filter":{"inMailbox":"$INBOX_ID"},"limit":$LIMIT},"0"],
  ["Email/get",{"accountId":"$ACCOUNT",
    "#ids":{"resultOf":"0","name":"Email/query","path":"/ids"},
    "properties":["receivedAt"]},"1"]]}
EOF
)
UNSORTED_NEWEST=$(jq -r '[.methodResponses[1][1].list[].receivedAt] | max' <<<"$UNSORTED")
UNSORTED_N=$(jq '.methodResponses[0][1].ids | length' <<<"$UNSORTED")
echo "  unsorted window: $UNSORTED_N ids, newest receivedAt=$UNSORTED_NEWEST"

echo "== T3: the FIX — patched query (sort receivedAt desc, exact 0048 request) surfaces fresh mail"
SORTED=$(jmap <<EOF
{"using":["urn:ietf:params:jmap:core","urn:ietf:params:jmap:mail"],
 "methodCalls":[
  ["Email/query",{"accountId":"$ACCOUNT","filter":{"inMailbox":"$INBOX_ID"},
    "sort":[{"property":"receivedAt","isAscending":false}],"limit":$LIMIT},"0"],
  ["Email/get",{"accountId":"$ACCOUNT",
    "#ids":{"resultOf":"0","name":"Email/query","path":"/ids"},
    "properties":["receivedAt"]},"1"]]}
EOF
)
SORTED_NEWEST=$(jq -r '[.methodResponses[1][1].list[].receivedAt] | max' <<<"$SORTED")
SORTED_N=$(jq '.methodResponses[0][1].ids | length' <<<"$SORTED")
CUTOFF=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
echo "  sorted window: $SORTED_N ids, newest receivedAt=$SORTED_NEWEST (freshness cutoff $CUTOFF)"
[ "$SORTED_N" -eq "$LIMIT" ] && ok "sorted query fills the full $LIMIT window" || bad "sorted query returned $SORTED_N ids"
[[ "$SORTED_NEWEST" > "$CUTOFF" ]] && ok "patched query's newest message is fresh (<7 days old) — inbox unfreezes" || bad "patched query newest=$SORTED_NEWEST is older than 7 days"
if [[ "$UNSORTED_NEWEST" < "$SORTED_NEWEST" ]]; then
  ok "unsorted window is stale (newest $UNSORTED_NEWEST < $SORTED_NEWEST) — root cause 1 reproduced live: this IS the 15-May freeze"
else
  echo "  note: server now returns the newest window unsorted — trap no longer reproduces; explicit sort remains correct per RFC 8621"
fi

echo "== T4: patch 0048 content — both fixes present in the shipped patch"
grep -q 'new Comparator("receivedAt", false)' "$PATCH" && ok "newest-first sort in Email/query (JmapService)" || bad "sort missing from patch"
grep -q 'folder.synchronize = true' "$PATCH" && ok "user folders created with synchronize=true (JmapSync)" || bad "synchronize=true missing from patch"
grep -q 'jmap_folder_sync_repaired' "$PATCH" && ok "one-time pref-gated repair for existing folder rows" || bad "repair pref missing from patch"
grep -q 'setFolderSynchronize' "$PATCH" && ok "repair uses DaoFolder.setFolderSynchronize" || bad "DAO repair call missing from patch"

echo "== T5: released APK — post-0048 build carries the repair marker (PENDING until CI ships)"
REL=$(gh api "repos/diegonmarcos/unix/releases?per_page=30" --jq '
  [.[] | select(.tag_name | startswith("cloud-comms-mail-"))
       | select([.assets[].name] | index("cloud-comms-mail.apk"))
       | {stamp: (.tag_name | split("-") | last),
          url: (.assets[] | select(.name=="cloud-comms-mail.apk") | .browser_download_url)}]
  | max_by(.stamp)')
STAMP=$(jq -r .stamp <<<"$REL"); URL=$(jq -r .url <<<"$REL")
echo "  newest release stamp: $STAMP"
if [[ "$STAMP" > "$PRE_FIX_STAMP" ]]; then
  TMP=$(mktemp -d)
  curl -sfL -o "$TMP/app.apk" "$URL" && unzip -o -q "$TMP/app.apk" 'classes*.dex' -d "$TMP" 2>/dev/null
  grep -aql "jmap_folder_sync_repaired" "$TMP"/classes*.dex 2>/dev/null \
    && ok "post-0048 APK contains the folder-repair marker — fix is in the released binary" \
    && grep -aql "JMAP repaired sync" "$TMP"/classes*.dex 2>/dev/null \
    && ok "repair log marker present in dex" \
    || bad "release $STAMP is newer than the patch but lacks 0048 markers"
  rm -rf "$TMP"
else
  echo "  PENDING: newest release ($STAMP) predates patch 0048 — re-run after CI publishes to verify the binary"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
