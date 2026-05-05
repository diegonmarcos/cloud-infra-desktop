#!/usr/bin/env bash
# Tester (rule #5) — verify declared state matches device state.
# Exit non-zero on any divergence.
set -euo pipefail
source "$REPO_ROOT/lib/_engine.sh"

PASS=0 ; FAIL=0
PROFILES_PATH=$(data_path profiles)
APKS_PATH=$(data_path apks)
SETTINGS_PATH=$(data_path settings)
LOCK="$REPO_ROOT/dist/profiles.lock.json"
[[ -f "$LOCK" ]] || die "profiles.lock.json missing — run reconcile-profiles first"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1 — $2"; FAIL=$((FAIL+1)); }

# ── Profile parity ────────────────────────────────────────────────
log "Test: profile parity"
declared=$(jq -r '.profiles[].name' "$PROFILES_PATH" | sort)
device=$(adb_users | cut -d: -f2 | sort)
[[ "$declared" == "$device" ]] && ok "profiles match" \
  || fail "profile-set differs" "declared=[${declared//$'\n'/,}] device=[${device//$'\n'/,}]"

# ── App parity per profile ────────────────────────────────────────
log "Test: app parity per profile"
while IFS= read -r p; do
  name=$(jq -r '.name' <<<"$p")
  uid=$(jq -r --arg n "$name" '.resolved[] | select(.name==$n).user_id' "$LOCK")
  tags_re=$(jq -r '.include_apk_tags | join("|")' <<<"$p")
  declared_pkgs=$(jq -r --arg re "$tags_re" \
    '.apks[] | select(.tags[] | test("^("+$re+")$")) | .package' "$APKS_PATH" | sort -u)
  installed=$(adb_list_pkgs_user "$uid" | sort -u)
  missing=$(comm -23 <(echo "$declared_pkgs") <(echo "$installed") || true)
  if [[ -z "$missing" ]]; then ok "apps[$name]"
  else fail "apps[$name]" "missing: ${missing//$'\n'/,}"
  fi
done < <(jq -c '.profiles[]' "$PROFILES_PATH")

# ── Settings parity ───────────────────────────────────────────────
log "Test: settings parity"
jq -r '.by_profile | keys[]' "$SETTINGS_PATH" | while read -r prof; do
  uid=$(jq -r --arg n "$prof" '.resolved[] | select(.name==$n).user_id' "$LOCK")
  [[ -z "$uid" || "$uid" == "null" ]] && continue
  for ns in system secure global; do
    jq -r --arg p "$prof" --arg ns "$ns" \
      '.by_profile[$p][$ns] // {} | to_entries[] | "\(.key)\t\(.value)"' "$SETTINGS_PATH" |
    while IFS=$'\t' read -r key expected; do
      [[ -z "$key" ]] && continue
      actual=$(adb_settings_get "$uid" "$ns" "$key")
      [[ "$actual" == "$expected" ]] && ok "settings[$prof/$ns/$key]" \
        || fail "settings[$prof/$ns/$key]" "expected=$expected actual=$actual"
    done
  done
done

echo
log "Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
