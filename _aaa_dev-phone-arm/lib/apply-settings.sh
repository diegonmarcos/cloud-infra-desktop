#!/usr/bin/env bash
# Apply per-profile settings from data/settings.json via `settings put --user`.
set -euo pipefail
source "$REPO_ROOT/lib/_engine.sh"

SETTINGS_PATH=$(data_path settings)
LOCK="$REPO_ROOT/dist/profiles.lock.json"
[[ -f "$LOCK" ]] || die "profiles.lock.json missing — run reconcile-profiles first"

jq -r '.by_profile | keys[]' "$SETTINGS_PATH" | while read -r prof; do
  uid=$(jq -r --arg n "$prof" '.resolved[] | select(.name==$n).user_id' "$LOCK")
  [[ -z "$uid" || "$uid" == "null" ]] && { log "skip '$prof' (no resolved user)"; continue; }

  for ns in system secure global; do
    jq -r --arg p "$prof" --arg ns "$ns" \
      '.by_profile[$p][$ns] // {} | to_entries[] | "\(.key)\t\(.value)"' "$SETTINGS_PATH" |
    while IFS=$'\t' read -r key val; do
      [[ -z "$key" ]] && continue
      log "  set ${prof}(${uid}) ${ns}/${key} = ${val}"
      adb_settings_put "$uid" "$ns" "$key" "$val"
    done
  done
done
