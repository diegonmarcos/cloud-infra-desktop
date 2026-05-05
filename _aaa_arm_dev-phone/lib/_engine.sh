#!/usr/bin/env bash
# Shared engine helpers. Sourced by build.sh.
# Centralises all ADB invocations — no script outside this file should call adb directly.

log() { printf "\e[1;34m[engine]\e[0m %s\n" "$*" >&2; }
die() { printf "\e[1;31m[FATAL]\e[0m %s\n" "$*" >&2; exit 1; }

run_action() {
  local action="$1" rel
  rel=$(jq -er ".actions.\"$action\"" "$BUILD_JSON") || die "Unknown action: $action"
  local path="$REPO_ROOT/${rel#./}"
  [[ -x "$path" ]] || die "Action script not executable: $path  (chmod +x)"
  log "▶ $action"
  bash "$path"
}

# Resolve a build.json data-file pointer (e.g. ".data.profiles") to an absolute path.
data_path() {
  local key="$1" rel
  rel=$(jq -er ".data.\"$key\"" "$BUILD_JSON") || die "Unknown data key: $key"
  printf '%s\n' "$REPO_ROOT/${rel#./}"
}

# ADB primitives — use these, never raw adb. Keeps engine universal (rule #2 of philosophy).
adb_users()                 { adb shell pm list users | awk -F'[{}:]' '/UserInfo/{print $2":"$3}'; }
adb_create_user()           { adb shell pm create-user "$1" | awk '{print $NF}' | tr -d '\r'; }
adb_list_pkgs_user()        { adb shell pm list packages --user "$1" | sed 's/^package://' | tr -d '\r'; }
adb_install_user()          { adb install --user "$1" "$2"; }
adb_install_existing_user() { adb shell pm install-existing --user "$1" "$2"; }
adb_uninstall_user()        { adb shell pm uninstall --user "$1" "$2"; }
adb_settings_put()          { adb shell settings put --user "$1" "$2" "$3" "$4"; }
adb_settings_get()          { adb shell settings get --user "$1" "$2" "$3" | tr -d '\r'; }
adb_grant()                 { adb shell pm grant   --user "$1" "$2" "$3"; }
adb_revoke()                { adb shell pm revoke  --user "$1" "$2" "$3"; }
adb_appops_set()            { adb shell appops set --user "$1" "$2" "$3" "$4"; }
