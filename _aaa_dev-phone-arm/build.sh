#!/usr/bin/env bash
# Universal engine for declarative phone provisioning.
# All data comes from build.json + data/*.json — never inline args (rule #1).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT
export BUILD_JSON="$REPO_ROOT/build.json"

[[ -f "$BUILD_JSON" ]]   || { echo "FATAL: build.json missing"  >&2; exit 1; }
command -v jq  >/dev/null || { echo "FATAL: jq required"        >&2; exit 1; }
command -v adb >/dev/null || { echo "FATAL: adb required"       >&2; exit 1; }

# shellcheck source=lib/_engine.sh
source "$REPO_ROOT/lib/_engine.sh"

CMD="${1:-help}"

if pipeline=$(jq -er ".pipelines.\"$CMD\" | join(\" \")" "$BUILD_JSON" 2>/dev/null); then
  log "Pipeline ⇒ $CMD : $pipeline"
  for action in $pipeline; do run_action "$action"; done
elif jq -er ".actions.\"$CMD\"" "$BUILD_JSON" >/dev/null 2>&1; then
  run_action "$CMD"
else
  echo "Usage: build.sh {<pipeline>|<action>}"
  echo "  pipelines:" ; jq -r '.pipelines | keys[] | "    " + .' "$BUILD_JSON"
  echo "  actions:"   ; jq -r '.actions   | keys[] | "    " + .' "$BUILD_JSON"
  exit 1
fi
