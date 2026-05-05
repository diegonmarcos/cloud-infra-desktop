#!/usr/bin/env bash
# Install APKs into each profile based on tag intersection (profiles.include_apk_tags ∩ apks.tags).
# Prefers `pm install-existing` when the package is already in the owner profile (faster).
set -euo pipefail
source "$REPO_ROOT/lib/_engine.sh"

PROFILES_PATH=$(data_path profiles)
APKS_PATH=$(data_path apks)
LOCK="$REPO_ROOT/dist/profiles.lock.json"
[[ -f "$LOCK" ]] || die "profiles.lock.json missing — run reconcile-profiles first"

while IFS= read -r profile; do
  name=$(jq -r '.name' <<<"$profile")
  uid=$(jq -r --arg n "$name" '.resolved[] | select(.name==$n).user_id' "$LOCK")
  tags_re=$(jq -r '.include_apk_tags | join("|")' <<<"$profile")
  log "Profile '$name' (user $uid) matching tags: $tags_re"

  installed=$(adb_list_pkgs_user "$uid")

  jq -c --arg re "$tags_re" '.apks[] | select(.tags[] | test("^("+$re+")$"))' "$APKS_PATH" |
  while IFS= read -r apk; do
    pkg=$(jq -r '.package' <<<"$apk")
    if grep -qx "$pkg" <<<"$installed"; then
      log "  ✓ $pkg present"
    else
      apk_file="$REPO_ROOT/dist/apks/${pkg}.apk"
      if [[ -f "$apk_file" ]]; then
        log "  + install $pkg from dist/"
        adb_install_user "$uid" "$apk_file"
      else
        log "  + install-existing $pkg (from owner)"
        adb_install_existing_user "$uid" "$pkg" \
          || log "  ! $pkg not in dist/ and not in owner — provision dist/apks/${pkg}.apk via flake"
      fi
    fi
  done
done < <(jq -c '.profiles[]' "$PROFILES_PATH")
