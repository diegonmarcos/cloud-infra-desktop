# plasma-fix-missing-panel-widgets.sh — generated from plasma.nix, do not edit by hand.
#
# WHY THIS EXISTS: when top-panel.json declares the SAME plugin id
# (com.diegonmarcos.watchdog) more than twice in one panel, plasma-manager
# emits a single evaluateScript D-Bus call containing all of that panel's
# addWidget(...) calls back to back. Only the first two of three identical
# addWidget calls land in plasma-org.kde.plasma.desktop-appletsrc — the
# third is silently dropped inside plasmashell's script engine. The repo
# side (top-panel.json / top-panel.nix / plasma.nix) is provably correct;
# the loss happens downstream of what Nix can control, so this is a
# post-hoc repair pass, not a config fix. It runs on EVERY activation and
# must be a no-op once the widget is present.
#
# Fully runtime-data-driven: the list of widgets to repair is read from
# plasma-panel-repair.json via jq at RUNTIME. Nothing about which panel,
# which plugin, or which config values is baked in by Nix interpolation —
# see plasma.nix for how this script is wired (writeShellApplication +
# xdg.configFile deploy of the JSON) and plasma-panel-repair.json for the
# widget list + rationale.
#
# Each missing widget gets its OWN separate evaluateScript call. That is
# the actual point of this script: batching multiple addWidget calls in
# one evaluateScript is what triggers the drop in the first place, so the
# repair must never do that either.
#
# This must NEVER fail a home-manager activation. Any missing tool,
# unreachable D-Bus, absent plasmashell, or bad JSON is a warning and an
# `exit 0`, not a hard failure — a broken panel widget is a cosmetic
# problem; a broken activation is not.
set -u

log() { echo "[plasma-fix-missing-panel-widgets] $*" >&2; }

JSON_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/plasma-panel-repair.json"
APPLETS_FILE="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"

command -v jq >/dev/null 2>&1 || { log "jq not found — skipping"; exit 0; }
command -v awk >/dev/null 2>&1 || { log "awk not found — skipping"; exit 0; }

QDBUS="$(command -v qdbus6 || command -v qdbus || true)"
[ -n "$QDBUS" ] || { log "qdbus not found — skipping"; exit 0; }

if command -v pgrep >/dev/null 2>&1; then
  pgrep -x plasmashell >/dev/null 2>&1 || { log "plasmashell not running — skipping"; exit 0; }
fi

[ -f "$JSON_FILE" ] || { log "no repair manifest at $JSON_FILE — skipping"; exit 0; }
[ -f "$APPLETS_FILE" ] || { log "no appletsrc yet at $APPLETS_FILE — skipping"; exit 0; }

jq empty "$JSON_FILE" >/dev/null 2>&1 || { log "$JSON_FILE is not valid JSON — skipping"; exit 0; }

WIDGET_COUNT="$(jq '.widgets | length' "$JSON_FILE" 2>/dev/null)"
case "$WIDGET_COUNT" in
  '' | *[!0-9]*) log "could not read .widgets from $JSON_FILE — skipping"; exit 0 ;;
esac
[ "$WIDGET_COUNT" -gt 0 ] || { log "no widgets listed in $JSON_FILE — nothing to do"; exit 0; }

# panel_location -> KDE Plasma::Types::Location numeric code, as written to
# [Containments][N] "location=" in the appletsrc (verified against the live
# file: TopEdge panels write location=3, BottomEdge location=4).
location_to_code() {
  case "$1" in
    floating) echo 0 ;;
    top) echo 3 ;;
    bottom) echo 4 ;;
    left) echo 5 ;;
    right) echo 6 ;;
    *) echo "" ;;
  esac
}

i=0
while [ "$i" -lt "$WIDGET_COUNT" ]; do
  ENTRY="$(jq -c ".widgets[$i]" "$JSON_FILE" 2>/dev/null)"
  i=$((i + 1))
  [ -n "$ENTRY" ] || continue

  PANEL_LOC="$(echo "$ENTRY" | jq -r '.panel_location // empty')"
  PLUGIN="$(echo "$ENTRY" | jq -r '.plugin // empty')"
  if [ -z "$PANEL_LOC" ] || [ -z "$PLUGIN" ]; then
    log "entry $((i - 1)) missing panel_location or plugin — skipping entry"
    continue
  fi

  LOC_CODE="$(location_to_code "$PANEL_LOC")"
  if [ -z "$LOC_CODE" ]; then
    log "entry $((i - 1)) has unrecognised panel_location '$PANEL_LOC' — skipping entry"
    continue
  fi

  # Find the containment id of the panel at this screen edge: the first
  # [Containments][N] block (no nested subsection) whose direct keys carry
  # both plugin=org.kde.panel and location=$LOC_CODE. Same awk convention
  # as fixBatteryPercentage in plasma.nix — track the current
  # top-level containment header, stop collecting at the next "[" line, and
  # only match keys seen before that boundary.
  CONTAINMENT_ID="$(awk -v loc="$LOC_CODE" '
    /^\[Containments\]\[[0-9]+\]$/ {
      if (cid != "" && is_panel && loc_val == loc) { print cid; found=1; exit }
      cid=$0; gsub(/\[Containments\]\[|\]/, "", cid); is_panel=0; loc_val=""
      next
    }
    /^\[/ { next }
    /^plugin=org\.kde\.panel$/ { is_panel=1 }
    /^location=/ { loc_val=$0; sub(/^location=/, "", loc_val) }
    END { if (!found && cid != "" && is_panel && loc_val == loc) print cid }
  ' "$APPLETS_FILE")"

  if [ -z "$CONTAINMENT_ID" ]; then
    log "no panel containment found for location '$PANEL_LOC' (entry $((i - 1))) — skipping entry"
    continue
  fi

  # Applet ids inside that containment whose plugin matches.
  APPLET_IDS=()
  while IFS= read -r aid; do
    [ -n "$aid" ] && APPLET_IDS+=("$aid")
  done < <(awk -v cid="$CONTAINMENT_ID" -v plugin="$PLUGIN" '
    $0 ~ ("^\\[Containments\\]\\[" cid "\\]\\[Applets\\]\\[[0-9]+\\]$") {
      aid = $0; gsub(/.*\[Applets\]\[|\]$/, "", aid); next
    }
    $0 == "plugin=" plugin { print aid }
  ' "$APPLETS_FILE")

  # Flattened "group\tkey\tvalue" rows for every key this entry's config
  # declares — used below to test whether a candidate applet already has
  # them all written.
  CONFIG_ROWS=()
  while IFS= read -r row; do
    [ -n "$row" ] && CONFIG_ROWS+=("$row")
  done < <(echo "$ENTRY" | jq -r '.config | to_entries[] as $g | $g.value | to_entries[] | [$g.key, .key, (.value|tostring)] | @tsv')

  # An applet already counts as "present" only if its plugin matches AND
  # every key/value pair this entry's config declares is already written
  # under that applet's [Configuration][<group>] section — this is what
  # tells apart the "left"/"right"/"guard" instances of the same plugin id.
  ALREADY_PRESENT=0
  for AID in "${APPLET_IDS[@]:-}"; do
    [ -n "$AID" ] || continue
    MATCH=1
    for ROW in "${CONFIG_ROWS[@]:-}"; do
      [ -n "$ROW" ] || continue
      GROUP="${ROW%%$'\t'*}"
      REST="${ROW#*$'\t'}"
      KEY="${REST%%$'\t'*}"
      VALUE="${REST#*$'\t'}"
      LINE_FOUND="$(awk -v pat="^\\[Containments\\]\\[$CONTAINMENT_ID\\]\\[Applets\\]\\[$AID\\]\\[Configuration\\]\\[$GROUP\\]$" -v want="$KEY=$VALUE" '
        $0 ~ pat { flag = 1; next }
        /^\[/ { flag = 0 }
        flag && $0 == want { print "yes"; exit }
      ' "$APPLETS_FILE")"
      if [ "$LINE_FOUND" != "yes" ]; then
        MATCH=0
        break
      fi
    done
    if [ "$MATCH" = 1 ]; then
      ALREADY_PRESENT=1
      break
    fi
  done

  if [ "$ALREADY_PRESENT" = 1 ]; then
    log "widget '$PLUGIN' (entry $((i - 1))) already present in '$PANEL_LOC' panel — nothing to do"
    continue
  fi

  # Build ONE evaluateScript call for ONLY this widget: addWidget() plus its
  # config writeConfig() calls, one call per group declared in the JSON.
  JS_CONFIG="$(echo "$ENTRY" | jq -r '
    .config | to_entries[] |
    "w.currentConfigGroup = [\"" + .key + "\"];\n" +
    ( .value | to_entries | map(
        if (.value | type) == "number"
        then "w.writeConfig(\"" + .key + "\", " + (.value | tostring) + ");"
        else "w.writeConfig(\"" + .key + "\", \"" + (.value | tostring) + "\");"
        end
      ) | join("\n")
    )
  ' 2>/dev/null)"

  SCRIPT="var panel = panelById($CONTAINMENT_ID); var w = panel.addWidget(\"$PLUGIN\"); $JS_CONFIG w.reloadConfig();"

  if OUTPUT="$("$QDBUS" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$SCRIPT" 2>&1)"; then
    if [ -n "$OUTPUT" ]; then
      log "evaluateScript for '$PLUGIN' (entry $((i - 1))) returned: $OUTPUT"
    else
      log "added widget '$PLUGIN' to '$PANEL_LOC' panel (entry $((i - 1)))"
    fi
  else
    log "evaluateScript call failed for '$PLUGIN' (entry $((i - 1))) — plasmashell/D-Bus unreachable, skipping"
  fi
done

exit 0
