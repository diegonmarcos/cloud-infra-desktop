#!/usr/bin/env bash
# Grant/revoke runtime permissions per profile from data/permissions.json.
set -euo pipefail
source "$REPO_ROOT/lib/_engine.sh"

PERMS_PATH=$(data_path permissions)
LOCK="$REPO_ROOT/dist/profiles.lock.json"
[[ -f "$LOCK" ]] || die "profiles.lock.json missing — run reconcile-profiles first"

jq -r '.by_profile | keys[]' "$PERMS_PATH" | while read -r prof; do
  uid=$(jq -r --arg n "$prof" '.resolved[] | select(.name==$n).user_id' "$LOCK")
  [[ -z "$uid" || "$uid" == "null" ]] && continue

  for action in revoke grant; do
    jq -c --arg p "$prof" --arg a "$action" '.by_profile[$p][$a] // [] | .[]' "$PERMS_PATH" |
    while IFS= read -r item; do
      pkg=$(jq -r '.package'    <<<"$item")
      perm=$(jq -r '.permission' <<<"$item")
      log "  ${action} ${prof}(${uid}) ${pkg} : ${perm}"
      if [[ "$action" == "grant" ]]; then
        adb_grant  "$uid" "$pkg" "$perm" || log "    ! grant failed (package may not be installed in profile)"
      else
        adb_revoke "$uid" "$pkg" "$perm" || log "    ! revoke failed"
      fi
    done
  done
done
