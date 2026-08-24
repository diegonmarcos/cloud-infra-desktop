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
# LIVE STATE, NOT THE FILE: widgets are added over D-Bus into the LIVE
# plasmashell process, but plasmashell only flushes its in-memory state to
# plasma-org.kde.plasma.desktop-appletsrc lazily. Deciding "is this widget
# already present?" by parsing that file therefore misses whatever this
# script itself (or plasma-manager's own batched activation script moments
# earlier in the same activation) just added — every run would think its
# own previous additions never happened and pile up more duplicates. So
# this script never reads or greps the appletsrc file at all: every
# presence/duplicate/orphan decision below comes from a single live
# evaluateScript inventory call (panels() / widgetIds / widgetById /
# currentConfigGroup / readConfig), taken once at the start of the run.
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
# DUPLICATES + ORPHANS: because a stale build of this script used to decide
# presence from the lazily-flushed file, a single activation could see its
# own additions as "missing" and add them again — e.g. guard x4, cpu x2,
# network x2, psi x2, proctable x1, storage/mem missing entirely, observed
# live 2026-08-11. The live inventory below removes that failure mode at
# the root, but existing duplicates left over from before this fix still
# need a cleanup pass: after the inventory is read, any (panel, plugin,
# mode) combination seen more than once has every instance but the first
# (in panel.widgetIds order, i.e. the oldest surviving one) queued for
# removal. Separately, a widget mode retired from the JSON (e.g. the old
# left/right modes) would otherwise linger in the live appletsrc forever —
# nothing else ever removes it — so any applet whose plugin ==
# watchdog_orphan_scope.plugin and whose mode is not in
# watchdog_orphan_scope.desired_modes is queued for removal too, scoped
# strictly to that one plugin id (checked via each applet's own .type
# before it is even added to the inventory). Both kinds of removal are
# decided from the SAME inventory snapshot and executed together in one
# final evaluateScript call, with every removal logged beforehand (panel,
# plugin, mode, applet id, and why).
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
# first place, so the repair must never do that either. Removal (dedup +
# orphans) is not subject to that same batching drop — remove() is not an
# addWidget() for a custom plugin — so it runs as a single additional
# evaluateScript call, once, after every repair entry above has been
# processed.
#
# IDEMPOTENCY: on a second consecutive run, the live inventory already shows
# exactly one applet per desired (panel, plugin, mode) — so the add loop
# finds every entry ALREADY_PRESENT and does nothing, and the dedup/orphan
# pass finds no (panel, plugin, mode) key repeated and no mode outside
# desired_modes, so it queues nothing and logs "nothing to remove". Neither
# pass depends on the other's outcome only being safe once — both branches
# are re-derived from live state every run.
#
# This must NEVER fail a home-manager activation. Any missing tool,
# unreachable D-Bus, absent plasmashell, or bad JSON is a warning and an
# `exit 0`, not a hard failure — a broken panel widget is a cosmetic
# problem; a broken activation is not.
set -u

log() { echo "[plasma-fix-missing-panel-widgets] $*" >&2; }

JSON_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/plasma-panel-repair.json"

command -v jq >/dev/null 2>&1 || { log "jq not found — skipping"; exit 0; }

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

jq empty "$JSON_FILE" >/dev/null 2>&1 || { log "$JSON_FILE is not valid JSON — skipping"; exit 0; }

WIDGET_COUNT="$(jq '.widgets | length' "$JSON_FILE" 2>/dev/null)"
case "$WIDGET_COUNT" in
  '' | *[!0-9]*) log "could not read .widgets from $JSON_FILE — skipping"; exit 0 ;;
esac

ORPHAN_PLUGIN="$(jq -r '.watchdog_orphan_scope.plugin // empty' "$JSON_FILE" 2>/dev/null)"
DESIRED_MODES_JSON="$(jq -c '.watchdog_orphan_scope.desired_modes // empty' "$JSON_FILE" 2>/dev/null)"

# Every plugin id this script is allowed to look at live: the plugins named
# by each repair entry, plus the orphan-sweep plugin, deduplicated. Scoping
# the inventory query to this set is what keeps every decision below
# (presence, dedup, orphan) "strictly scoped to plugin ==
# com.diegonmarcos.watchdog" even though the mechanism itself is generic.
SCOPE_PLUGINS_JSON="$(jq -c '
  [ (.widgets // [])[].plugin, (.watchdog_orphan_scope.plugin // empty) ]
  | map(select(. != "" and . != null)) | unique
' "$JSON_FILE" 2>/dev/null)" || SCOPE_PLUGINS_JSON=""
case "$SCOPE_PLUGINS_JSON" in
  '['*']') ;;
  *) log "could not determine plugin scope from $JSON_FILE — skipping"; exit 0 ;;
esac

# ─────────────────────────────────────────────────────────────────────────
# LIVE INVENTORY — the fix for the core bug. ONE evaluateScript call reads
# plasmashell's actual current state (never the lazily-flushed appletsrc
# file) and prints it as tab-separated records:
#   PANEL<TAB>location<TAB>containment-id            (one per existing panel)
#   APPLET<TAB>location<TAB>plugin<TAB>mode<TAB>id    (one per in-scope applet)
# panel.location is documented (develop.kde.org/docs/plasma/scripting/api)
# to already be the strings "top"/"bottom"/"left"/"right"/"floating" — the
# exact values top-panel.json/bottom-panel.json use for panel_location — so
# no numeric-code translation is needed to match live panels against the
# JSON manifest.
# ─────────────────────────────────────────────────────────────────────────
INVENTORY_SCRIPT="
  var scopePlugins = $SCOPE_PLUGINS_JSON;
  var allPanels = panels();
  for (var pi = 0; pi < allPanels.length; pi++) {
    var pnl = allPanels[pi];
    print(\"PANEL\t\" + pnl.location + \"\t\" + pnl.id);
    var wids = pnl.widgetIds;
    for (var wi = 0; wi < wids.length; wi++) {
      var wd = pnl.widgetById(wids[wi]);
      var inScope = false;
      for (var si = 0; si < scopePlugins.length; si++) {
        if (scopePlugins[si] === wd.type) { inScope = true; break; }
      }
      if (!inScope) continue;
      wd.currentConfigGroup = [\"General\"];
      var m = wd.readConfig(\"mode\", \"\");
      print(\"APPLET\t\" + pnl.location + \"\t\" + wd.type + \"\t\" + m + \"\t\" + wids[wi]);
    }
  }
"

if ! INVENTORY_OUTPUT="$("$QDBUS" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$INVENTORY_SCRIPT" 2>&1)"; then
  log "live inventory evaluateScript call failed — plasmashell/D-Bus unreachable, skipping"
  exit 0
fi

declare -A PANEL_CID=()
APPLET_LOC=()
APPLET_PLUGIN=()
APPLET_MODE=()
APPLET_ID=()

# Parse the inventory. PANEL rows populate PANEL_CID (location -> live
# containment id, used both to add new widgets and to remove stale ones).
# APPLET rows populate the four parallel arrays below, in the same order
# plasmashell reported them (panel.widgetIds order) — which is what makes
# "first seen" a well-defined survivor for the dedup pass further down.
while IFS=$'\t' read -r tag a b c d; do
  case "$tag" in
    PANEL) PANEL_CID["$a"]="$b" ;;
    APPLET)
      APPLET_LOC+=("$a")
      APPLET_PLUGIN+=("$b")
      APPLET_MODE+=("$c")
      APPLET_ID+=("$d")
      ;;
    *) : ;;
  esac
done <<< "$INVENTORY_OUTPUT"

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

    # Identity for live presence checks is config.General.mode — the same
    # key the JSON already uses to distinguish otherwise-identical
    # com.diegonmarcos.watchdog instances from one another.
    MODE="$(echo "$ENTRY" | jq -r '.config.General.mode // empty')"
    if [ -z "$MODE" ]; then
      log "entry $((i - 1)) has no config.General.mode — cannot determine live presence, skipping entry"
      continue
    fi

    CONTAINMENT_ID="${PANEL_CID[$PANEL_LOC]:-}"
    if [ -z "$CONTAINMENT_ID" ]; then
      log "no panel containment found for location '$PANEL_LOC' (entry $((i - 1))) — skipping entry"
      continue
    fi

    # Present if the live inventory already has an applet of this plugin
    # and mode on this panel — no file, no re-read, just what plasmashell
    # itself reports right now (including anything already added earlier
    # in this very run).
    ALREADY_PRESENT=0
    ai=0
    while [ "$ai" -lt "${#APPLET_ID[@]}" ]; do
      if [ "${APPLET_LOC[$ai]}" = "$PANEL_LOC" ] && [ "${APPLET_PLUGIN[$ai]}" = "$PLUGIN" ] && [ "${APPLET_MODE[$ai]}" = "$MODE" ]; then
        ALREADY_PRESENT=1
        break
      fi
      ai=$((ai + 1))
    done

    if [ "$ALREADY_PRESENT" = 1 ]; then
      log "widget '$PLUGIN' mode='$MODE' (entry $((i - 1))) already present in '$PANEL_LOC' panel — nothing to do"
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
# DEDUP + ORPHAN SWEEP — decided entirely from the inventory snapshot taken
# at the top of this run (never re-scanned), so it targets exactly the
# duplicates/orphans a broken prior run left behind, plus anything the add
# loop above just created cannot be a duplicate of (each entry only adds
# when no live instance exists yet). For each (panel, plugin, mode) key,
# the FIRST applet id encountered — panel.widgetIds order, i.e. the oldest
# surviving instance — is kept; every later match for the same key is
# removed. Independently, any surviving applet whose plugin equals
# watchdog_orphan_scope.plugin and whose mode is outside desired_modes is
# also removed. Both were already filtered to the SCOPE_PLUGINS_JSON set
# (checked via each applet's own .type) when the live inventory above was
# built, so this sweep never touches anything outside that plugin scope.
# ─────────────────────────────────────────────────────────────────────────
declare -A SEEN_SURVIVOR=()
REMOVE_CID=()
REMOVE_AID=()
REMOVE_REASON=()

ai=0
while [ "$ai" -lt "${#APPLET_ID[@]}" ]; do
  loc="${APPLET_LOC[$ai]}"
  plugin="${APPLET_PLUGIN[$ai]}"
  mode="${APPLET_MODE[$ai]}"
  aid="${APPLET_ID[$ai]}"
  cid="${PANEL_CID[$loc]:-}"
  ai=$((ai + 1))

  if [ -z "$cid" ]; then
    log "no containment id resolved for panel '$loc' — cannot evaluate applet id=$aid for dedup/orphan, skipping"
    continue
  fi

  key="$loc"$'\t'"$plugin"$'\t'"$mode"
  if [ -n "${SEEN_SURVIVOR[$key]:-}" ]; then
    REMOVE_CID+=("$cid")
    REMOVE_AID+=("$aid")
    REMOVE_REASON+=("duplicate: panel='$loc' plugin='$plugin' mode='$mode' id=$aid (kept id=${SEEN_SURVIVOR[$key]})")
    continue
  fi
  SEEN_SURVIVOR["$key"]="$aid"

  if [ "$plugin" = "$ORPHAN_PLUGIN" ] && [ -n "$DESIRED_MODES_JSON" ]; then
    if ! echo "$DESIRED_MODES_JSON" | jq -e --arg m "$mode" 'index($m) != null' >/dev/null 2>&1; then
      REMOVE_CID+=("$cid")
      REMOVE_AID+=("$aid")
      REMOVE_REASON+=("orphan: panel='$loc' plugin='$plugin' mode='$mode' id=$aid not in desired_modes")
    fi
  fi
done

if [ "${#REMOVE_AID[@]}" -eq 0 ]; then
  log "dedup/orphan sweep: nothing to remove"
else
  ri=0
  while [ "$ri" -lt "${#REMOVE_AID[@]}" ]; do
    log "queued removal — ${REMOVE_REASON[$ri]}"
    ri=$((ri + 1))
  done

  REMOVE_PAIRS_JSON="$(
    ri=0
    while [ "$ri" -lt "${#REMOVE_AID[@]}" ]; do
      printf '%s\t%s\n' "${REMOVE_CID[$ri]}" "${REMOVE_AID[$ri]}"
      ri=$((ri + 1))
    done | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | map(tonumber))' 2>/dev/null
  )" || REMOVE_PAIRS_JSON=""

  case "$REMOVE_PAIRS_JSON" in
    '['*']')
      REMOVE_SCRIPT="
        var toRemove = $REMOVE_PAIRS_JSON;
        for (var ri = 0; ri < toRemove.length; ri++) {
          var cid = toRemove[ri][0];
          var aid = toRemove[ri][1];
          var pnl = panelById(cid);
          var wd = pnl.widgetById(aid);
          print(\"removed id=\" + aid + \" type=\" + wd.type + \" from panel id=\" + cid);
          wd.remove();
        }
      "
      if OUTPUT="$("$QDBUS" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$REMOVE_SCRIPT" 2>&1)"; then
        log "dedup/orphan sweep: ${OUTPUT:-removed ${#REMOVE_AID[@]} applet(s)}"
      else
        log "dedup/orphan sweep evaluateScript call failed — plasmashell/D-Bus unreachable, skipping"
      fi
      ;;
    *)
      log "could not build removal script from queued removals — skipping removal sweep"
      ;;
  esac
fi

exit 0
