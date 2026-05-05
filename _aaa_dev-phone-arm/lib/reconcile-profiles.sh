#!/usr/bin/env bash
# Create users declared in data/profiles.json that don't yet exist.
# Writes dist/profiles.lock.json mapping name -> resolved user_id (stable across runs).
set -euo pipefail
source "$REPO_ROOT/lib/_engine.sh"

PROFILES_PATH=$(data_path profiles)
LOCK="$REPO_ROOT/dist/profiles.lock.json"
mkdir -p "$(dirname "$LOCK")"
echo '{"resolved":[]}' > "$LOCK"

declare -A EXISTING
while IFS=: read -r id name; do EXISTING["$name"]="$id"; done < <(adb_users)

while IFS= read -r p; do
  name=$(jq -r '.name'    <<<"$p")
  type=$(jq -r '.type'    <<<"$p")
  declared_id=$(jq -r '.user_id' <<<"$p")

  if [[ -n "${EXISTING[$name]:-}" ]]; then
    real_id="${EXISTING[$name]}"
    log "✓ profile '$name' exists → user $real_id"
  elif [[ "$type" == "owner" ]]; then
    real_id="$declared_id"
    log "✓ owner profile pinned to user $real_id"
  else
    log "+ creating profile '$name'"
    real_id=$(adb_create_user "$name")
  fi

  jq --arg n "$name" --argjson id "$real_id" \
     '.resolved += [{name:$n, user_id:$id}]' "$LOCK" > "$LOCK.tmp" && mv "$LOCK.tmp" "$LOCK"
done < <(jq -c '.profiles[]' "$PROFILES_PATH")

log "Profile lock: $LOCK"
