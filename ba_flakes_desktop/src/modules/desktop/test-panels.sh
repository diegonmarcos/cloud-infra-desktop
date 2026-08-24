#!/usr/bin/env bash
# Data check for panels.json. Runs offline — no plasmashell, no D-Bus, no
# appletsrc. Replaces test-systray-config.sh, which tested a script that has
# been folded into plasma-panels-apply.sh.
#
# It checks the things that actually went wrong historically: a tray widget
# with no declared contents, an id declared in two trays, and an always_hidden
# id that some tray's shown list quietly re-shows (the complement is computed
# per tray, so a contradiction here is silent at runtime).
set -euo pipefail

JSON="${1:-$(dirname "$0")/panels.json}"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   — $1"; else echo "FAIL — $1: got '$2', want '$3'"; fail=1; fi; }

jq -e . "$JSON" >/dev/null && echo "ok   — panels.json is valid JSON"

check "every widget has a plugin" \
  "$(jq '[.panels[].widgets[] | select(has("plugin") | not)] | length' "$JSON")" 0

check "one shown list per systemtray widget" \
  "$(jq '[.panels[].widgets[] | select(.plugin == "org.kde.plasma.systemtray")] | length' "$JSON")" \
  "$(jq '[.panels[].widgets[] | select(has("shown"))] | length' "$JSON")"

check "only systemtray widgets carry a shown list" \
  "$(jq '[.panels[].widgets[] | select(has("shown") and .plugin != "org.kde.plasma.systemtray")] | length' "$JSON")" 0

check "no id is shown in two trays" \
  "$(jq '[.panels[].widgets[].shown // [] | .[]] | (length) - ([.[]] | unique | length)' "$JSON")" 0

check "no always_hidden id is also shown" \
  "$(jq '[.always_hidden[] as $h | [.panels[].widgets[].shown // [] | .[]] | index($h)] | map(select(. != null)) | length' "$JSON")" 0

check "every panel declares location and height" \
  "$(jq '[.panels[] | select((has("location") and has("height")) | not)] | length' "$JSON")" 0

exit "$fail"
