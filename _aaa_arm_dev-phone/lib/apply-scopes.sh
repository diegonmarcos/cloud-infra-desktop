#!/usr/bin/env bash
# GrapheneOS Storage/Contact/Calendar Scopes are not yet scriptable via stable AppOps codes.
# This action emits dist/scopes-checklist.md from data/scopes.json for manual application.
# Declarative-gap, surfaced honestly per rule #1 ("declared, then resolved").
set -euo pipefail
source "$REPO_ROOT/lib/_engine.sh"

SCOPES_PATH=$(data_path scopes)
OUT="$REPO_ROOT/dist/scopes-checklist.md"
mkdir -p "$(dirname "$OUT")"

{
  echo "# GrapheneOS Scopes — manual provisioning checklist"
  echo
  echo "_Generated from $(realpath --relative-to="$REPO_ROOT" "$SCOPES_PATH")._"
  echo "_Apply via: Settings → Apps → \<app\> → Permissions → Storage / Contacts / Calendar → Scopes._"
  echo
  jq -r '
    .by_profile | to_entries[] |
    "## Profile: " + .key + "\n" +
    ((.value.storage_scopes  // []) | map("- [ ] **Storage**  · " + .package + " → " + (.allow_paths    // [] | tostring)) | join("\n")) + "\n" +
    ((.value.contact_scopes  // []) | map("- [ ] **Contacts** · " + .package + " → " + (.allow_groups   // [] | tostring)) | join("\n")) + "\n" +
    ((.value.calendar_scopes // []) | map("- [ ] **Calendar** · " + .package + " → " + (.allow_calendars// [] | tostring)) | join("\n")) + "\n"
  ' "$SCOPES_PATH"
} > "$OUT"

log "Scopes checklist: $OUT"
log "⚠ Manual step required (declarative gap — upstream API pending)."
