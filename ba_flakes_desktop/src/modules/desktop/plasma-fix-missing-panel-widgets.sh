# plasma-fix-missing-panel-widgets.sh — generated from plasma.nix, do not edit by hand.
#
# WHY THIS EXISTS: when top-panel.json/bottom-panel.json declare the SAME
# plugin id (com.diegonmarcos.watchdog) more than twice ACROSS THE WHOLE
# activation, plasma-manager emits a single evaluateScript D-Bus call
# containing every panel's addWidget(...) calls back to back. Only the first
# two addWidget calls for a given plugin id land in
# plasma-org.kde.plasma.desktop-appletsrc — every one after that is silently
# dropped inside plasmashell's script engine, counted per plugin id across
# the ENTIRE script, not per panel. The repo side (top-panel.json /
# bottom-panel.json / *.nix / plasma.nix) is provably correct; the loss
# happens downstream of what Nix can control, so this is a post-hoc repair
# pass, not a config fix. It runs on EVERY activation and must be a no-op
# once a widget is present.
#
# ORDERING: this repair pass is add-only, and plasmashell always appends a
# freshly-added widget to the END of its containment's applet list. Appending
# every repaired widget would put it after everything else regardless of
# where the source JSON actually declared it — reproducing the exact
# "widgets in the wrong place" problem this script exists to fix. So each
# repaired widget may carry an "insert_after" anchor (see
# plasma-panel-repair.json for the full rationale) and, once added, this
# script splices its id into the containment's AppletOrder config key right
# after that anchor — resolved against the LIVE plasmashell process
# (panel.widgetIds / widgetById / readConfig), never by re-reading the file,
# so a chain of repaired widgets anchored to each other still resolves
# correctly within one run. AppletOrder is used because the Plasma desktop
# scripting API (develop.kde.org/docs/plasma/scripting/api) documents no
# "move applet to index N" call for containments or applets — addWidget only
# ever appends, and AppletOrder is the sole supported way to change display
# order afterward. This script never hand-edits the appletsrc file directly;
# every mutation, including the reorder, goes through the same
# evaluateScript D-Bus mechanism plasma-manager itself uses.
#
# ORPHANS: because the repair pass above is strictly additive, a widget mode
# retired from the JSON (e.g. the old left/right modes) would otherwise
# linger in the live appletsrc forever — nothing else ever removes it. A
# second, final evaluateScript sweep (driven by watchdog_orphan_scope in
# plasma-panel-repair.json) removes any applet with
# plugin==com.diegonmarcos.watchdog whose mode is not in the current desired
# set. Scoped strictly to that one plugin id — checked via each applet's own
# .type before it is touched — and every removal is logged.
#
# Fully runtime-data-driven: the list of widgets to repair, their insertion
# anchors, and the orphan mode set are all read from plasma-panel-repair.json
# via jq at RUNTIME. Nothing about which panel, which plugin, which config
# values, which anchor, or which modes are desired is baked in by Nix
# interpolation — see plasma.nix for how this script is wired
# (writeShellApplication + xdg.configFile deploy of the JSON) and
# plasma-panel-repair.json for the widget list + rationale.
#
# Each missing widget gets its OWN separate evaluateScript call (the
# reposition happens inside that SAME call, so it stays one D-Bus call per
# widget). That is the actual point of this script: batching multiple
# addWidget calls in one evaluateScript is what triggers the drop in the
# first place, so the repair must never do that either. The orphan sweep is
# a single additional evaluateScript call, run once at the end, after every
# repair entry has been processed.
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

# Probe the D-Bus endpoint, which is the actual dependency, rather than the
# process name. This used to be `pgrep -x plasmashell`, which NEVER matched on
# NixOS: the running binary is a wrapper, so /proc/<pid>/comm is
# ".plasmashell-wr" (comm is capped at 15 chars) and `pgrep -x plasmashell`
# exits 1. Every run of this script therefore logged "plasmashell not running"
# and exited 0 without repairing anything -- which is why the top panel kept
# its missing widgets no matter how many times activation ran.
"$QDBUS" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "1" >/dev/null 2>&1 || {
  log "plasmashell D-Bus endpoint unavailable — skipping"
  exit 0
}

[ -f "$JSON_FILE" ] || { log "no repair manifest at $JSON_FILE — skipping"; exit 0; }
[ -f "$APPLETS_FILE" ] || { log "no appletsrc yet at $APPLETS_FILE — skipping"; exit 0; }

jq empty "$JSON_FILE" >/dev/null 2>&1 || { log "$JSON_FILE is not valid JSON — skipping"; exit 0; }

WIDGET_COUNT="$(jq '.widgets | length' "$JSON_FILE" 2>/dev/null)"
case "$WIDGET_COUNT" in
  '' | *[!0-9]*) log "could not read .widgets from $JSON_FILE — skipping"; exit 0 ;;
esac

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

if [ "$WIDGET_COUNT" -gt 0 ]; then
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
    # tells apart the different mode= instances of the same plugin id.
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

    # Build ONE evaluateScript call for ONLY this widget: addWidget() plus
    # its config writeConfig() calls (one call per group declared in the
    # JSON), followed — if this entry declares an "insert_after" anchor — by
    # the AppletOrder splice that puts the new widget in its intended
    # position instead of leaving it appended at the end.
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

    ANCHOR_PLUGIN="$(echo "$ENTRY" | jq -r '.insert_after.plugin // empty')"
    ANCHOR_MODE="$(echo "$ENTRY" | jq -r '.insert_after.mode // empty')"
    ANCHOR_OCC="$(echo "$ENTRY" | jq -r '.insert_after.occurrence // empty')"

    REPOSITION_JS=""
    if [ -n "$ANCHOR_PLUGIN" ] && { [ -n "$ANCHOR_MODE" ] || [ -n "$ANCHOR_OCC" ]; }; then
      if [ -n "$ANCHOR_OCC" ]; then
        ANCHOR_SELECT_JS="var occAnchor = true; var wantOcc = $ANCHOR_OCC; var wantMode = \"\";"
      else
        ANCHOR_SELECT_JS="var occAnchor = false; var wantOcc = 0; var wantMode = \"$ANCHOR_MODE\";"
      fi
      REPOSITION_JS="
        var anchorPlugin = \"$ANCHOR_PLUGIN\";
        $ANCHOR_SELECT_JS
        var anchorId = -1; var occCount = 0;
        var scanIds = panel.widgetIds;
        for (var ai = 0; ai < scanIds.length; ai++) {
          if (scanIds[ai] === w.id) continue;
          var cw = panel.widgetById(scanIds[ai]);
          if (cw.type !== anchorPlugin) continue;
          if (occAnchor) {
            occCount = occCount + 1;
            if (occCount === wantOcc) { anchorId = scanIds[ai]; break; }
          } else {
            cw.currentConfigGroup = [\"General\"];
            if (cw.readConfig(\"mode\", \"\") === wantMode) { anchorId = scanIds[ai]; break; }
          }
        }
        if (anchorId !== -1) {
          var idsNow = panel.widgetIds;
          var kept = [];
          for (var bi = 0; bi < idsNow.length; bi++) { if (idsNow[bi] !== w.id) kept.push(idsNow[bi]); }
          var finalOrder = [];
          for (var ci = 0; ci < kept.length; ci++) {
            finalOrder.push(kept[ci]);
            if (kept[ci] === anchorId) finalOrder.push(w.id);
          }
          panel.currentConfigGroup = [\"General\"];
          panel.writeConfig(\"AppletOrder\", finalOrder.join(\";\"));
          panel.reloadConfig();
          print(\"repositioned id \" + w.id + \" after anchor id \" + anchorId);
        } else {
          print(\"WARNING: anchor not found for id \" + w.id + \" — left at end of panel\");
        }
      "
    fi

    SCRIPT="var panel = panelById($CONTAINMENT_ID); var w = panel.addWidget(\"$PLUGIN\"); $JS_CONFIG w.reloadConfig(); $REPOSITION_JS"

    if OUTPUT="$("$QDBUS" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$SCRIPT" 2>&1)"; then
      if [ -n "$OUTPUT" ]; then
        log "added widget '$PLUGIN' to '$PANEL_LOC' panel (entry $((i - 1))): $OUTPUT"
      else
        log "added widget '$PLUGIN' to '$PANEL_LOC' panel (entry $((i - 1)))"
      fi
    else
      log "evaluateScript call failed for '$PLUGIN' (entry $((i - 1))) — plasmashell/D-Bus unreachable, skipping"
    fi
  done
else
  log "no widgets listed in $JSON_FILE — nothing to repair"
fi

# ─────────────────────────────────────────────────────────────────────────
# Orphan sweep: remove any com.diegonmarcos.watchdog applet whose mode is no
# longer in the desired set. Runs once, after every repair entry above has
# had a chance to run, as its own separate evaluateScript call (a remove()
# call is not an addWidget() for a custom plugin, so it is not subject to
# the batching drop this script otherwise works around — one call for the
# whole sweep is fine). Strictly scoped to watchdog_orphan_scope.plugin.
# ─────────────────────────────────────────────────────────────────────────
ORPHAN_PLUGIN="$(jq -r '.watchdog_orphan_scope.plugin // empty' "$JSON_FILE" 2>/dev/null)"
DESIRED_MODES_JSON="$(jq -c '.watchdog_orphan_scope.desired_modes // empty' "$JSON_FILE" 2>/dev/null)"

if [ -n "$ORPHAN_PLUGIN" ] && [ -n "$DESIRED_MODES_JSON" ] && [ "$DESIRED_MODES_JSON" != "null" ]; then
  REMOVE_SCRIPT="
    var desiredModes = $DESIRED_MODES_JSON;
    var targetPlugin = \"$ORPHAN_PLUGIN\";
    var allPanels = panels();
    for (var pi = 0; pi < allPanels.length; pi++) {
      var pnl = allPanels[pi];
      var wids = pnl.widgetIds;
      for (var wi = 0; wi < wids.length; wi++) {
        var wd = pnl.widgetById(wids[wi]);
        if (wd.type !== targetPlugin) continue;
        wd.currentConfigGroup = [\"General\"];
        var m = wd.readConfig(\"mode\", \"\");
        var keep = false;
        for (var di = 0; di < desiredModes.length; di++) {
          if (desiredModes[di] === m) { keep = true; break; }
        }
        if (!keep) {
          print(\"removed orphan \" + targetPlugin + \" mode=\" + m + \" id=\" + wids[wi]);
          wd.remove();
        }
      }
    }
  "
  if OUTPUT="$("$QDBUS" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$REMOVE_SCRIPT" 2>&1)"; then
    if [ -n "$OUTPUT" ]; then
      log "orphan sweep: $OUTPUT"
    else
      log "orphan sweep: no orphan '$ORPHAN_PLUGIN' widgets found"
    fi
  else
    log "orphan sweep evaluateScript call failed — plasmashell/D-Bus unreachable, skipping"
  fi
else
  log "no watchdog_orphan_scope in $JSON_FILE — skipping orphan sweep"
fi

exit 0
