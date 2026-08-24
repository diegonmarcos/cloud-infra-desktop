# plasma-panels-apply.sh — THE panel applier. One runner, one definition
# (panels.json), one trigger (plasma-manager's run_all.sh autostart; the HM
# activation calls this same binary so a switch does not need a logout).
#
# Replaces plasma-panel-sync.sh + plasma-systray-config.sh +
# plasma-fix-missing-panel-widgets.sh and plasma-manager's own generated
# desktop_script_panels.js. See panels.json's _doc for why there were four.
#
# Two things Plasma forces this to be a script rather than a declaration:
#
#   1. ONE D-Bus call PER WIDGET. plasma-manager batches every addWidget()
#      across every panel into a single evaluateScript, and plasmashell
#      silently drops the 3rd+ addWidget() for the same custom KPackage plugin
#      id within one script (confirmed live 2026-08-07 and 2026-08-11: of seven
#      com.diegonmarcos.watchdog instances only storage and mem landed). One
#      call per widget never trips it, which is what makes the whole
#      insert_after / AppletOrder / orphan-sweep repair mechanism unnecessary
#      instead of merely relocated.
#
#   2. The tray CONTENTS are not settable from the scripting API at all.
#      Plasma reads shownItems/hiddenItems from the PRIVATE systemtray
#      containment, not from the applet; the Plasma scripting API exposes no
#      nested containment (upstream plasma-manager's system-tray.nix has the
#      same code commented out, waiting on exactly that). So the layout goes
#      over D-Bus and the tray lists go into appletsrc with kwriteconfig6.
#
# Idempotent and hash-gated: if panels.json is unchanged AND the live panel
# count matches, it does nothing at all. That is what lets the same binary run
# at activation and again at every login without fighting itself.
# No errexit: several steps return non-zero benignly (a kreadconfig6 for a key
# that does not exist yet, a busctl probe with nothing to report). Every step
# that MUST succeed is checked explicitly.
set -uo pipefail

JSON="${PANELS_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/cloud-data/panels.json}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/plasma-panels-applied"
APPLETS="${PANELS_APPLETSRC:-$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc}"

log() { echo "[panels] $*"; }

[ -f "$JSON" ] || { log "missing $JSON" >&2; exit 1; }

qd=""
for c in qdbus6 qdbus; do command -v "$c" >/dev/null 2>&1 && { qd="$c"; break; }; done
[ -n "$qd" ] || { log "no qdbus on PATH — nothing to do"; exit 0; }

evaluate() {
  "$qd" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$1" 2>&1
}

# ── wait for plasmashell ──────────────────────────────────────────────────
i=0
while [ "$i" -lt 60 ]; do
  evaluate "print('up')" 2>/dev/null | grep -q up && break
  i=$((i + 1))
  sleep 1
done
[ "$i" -lt 60 ] || { log "plasmashell never answered on D-Bus — giving up"; exit 0; }

# ── do we need to do anything? ────────────────────────────────────────────
want=$(jq '.panels | length' "$JSON")
have=$(evaluate "print(panels().length)" 2>/dev/null | tr -dc '0-9')
[ -n "$have" ] || have=0
cur_hash=$(sha256sum "$JSON" | cut -d' ' -f1)
old_hash=$(cat "$STATE" 2>/dev/null || echo "")

if [ "$cur_hash" = "$old_hash" ] && [ "$have" -eq "$want" ]; then
  log "panels: $have/$want, definition unchanged — nothing to do"
  exit 0
fi
log "panels: have $have, declared $want, definition $([ "$cur_hash" = "$old_hash" ] && echo current || echo changed) — rebuilding"

# ── layout: one call to clear, one per panel, one per widget ──────────────
# Nothing here reads the live appletsrc: a full rebuild from panels.json is
# the only writer, so a widget that is no longer declared is gone because it
# was never re-added, not because something deleted it afterwards.
evaluate "panels().forEach(function (p) { p.remove(); });" >/dev/null

n=0
while [ "$n" -lt "$want" ]; do
  js=$(jq -r --argjson n "$n" '.panels[$n] |
    "var p = new Panel();\np.location = \(.location|tojson);\np.height = \(.height);\np.floating = \(.floating);\np.alignment = \(.alignment // "center" | tojson);"' "$JSON")
  out=$(evaluate "$js")
  [ -n "$out" ] && log "panel $n: $out"
  n=$((n + 1))
done

have=$(evaluate "print(panels().length)" 2>/dev/null | tr -dc '0-9')
[ -n "$have" ] || have=0
if [ "$have" -ne "$want" ]; then
  log "ERROR: created $have/$want panels — leaving state unset so this retries"
  exit 1
fi

# One evaluateScript per widget. This loop is the fix for the addWidget
# batching bug; do not "optimise" it into a single call.
widgets=0
n=0
while [ "$n" -lt "$want" ]; do
  cnt=$(jq --argjson n "$n" '.panels[$n].widgets | length' "$JSON")
  w=0
  while [ "$w" -lt "$cnt" ]; do
    js=$(jq -r --argjson n "$n" --argjson w "$w" '
      .panels[$n].widgets[$w] as $x |
      "var w = panels()[\($n)].addWidget(\($x.plugin|tojson));" +
      ( ($x.config // {}) | to_entries | map(
          "\nw.currentConfigGroup = [\(.key|tojson)];" +
          ( .value | to_entries | map("\nw.writeConfig(\(.key|tojson), \(.value|tojson));") | join("") )
        ) | join("") )' "$JSON")
    out=$(evaluate "$js")
    [ -n "$out" ] && log "panel $n widget $w: $out"
    widgets=$((widgets + 1))
    w=$((w + 1))
  done
  n=$((n + 1))
done
log "layout: $want panels, $widgets widgets"

# plasmashell writes appletsrc asynchronously; the tray step below reads it.
sleep 3

# ── tray contents: appletsrc, because the scripting API cannot reach them ──
if [ ! -f "$APPLETS" ]; then
  log "no $APPLETS yet — skipping tray contents"
else
  # Private systemtray containments, in ascending id = creation order = the
  # order the systemtray widgets appear in panels.json.
  mapfile -t TRAYS < <(awk '
    /^\[Containments\]\[[0-9]+\]$/ { id = gensub(/.*\[([0-9]+)\]$/, "\\1", "g"); next }
    /^plugin=org\.kde\.plasma\.private\.systemtray$/ { if (id != "") print id }
  ' "$APPLETS" | sort -n)

  # The universe every hidden list is the complement of: everything any tray
  # already knows about, everything we declare, and — critically — every SNI
  # actually on the bus right now. An id nobody ever mentioned defaults to
  # SHOWN, so anything missing from this set leaks into a tray.
  universe=$(
    {
      for id in "${TRAYS[@]}"; do
        for key in knownItems extraItems shownItems hiddenItems; do
          kreadconfig6 --file "$APPLETS" --group Containments --group "$id" \
            --group General --key "$key"
        done
      done
      jq -r '[.panels[].widgets[] | .shown // [] | .[]] + .always_hidden | .[]' "$JSON"
      if command -v busctl >/dev/null 2>&1; then
        busctl --user list --no-legend 2>/dev/null |
          awk '/^org\.kde\.StatusNotifierItem-/ { print $1 }' |
          while read -r _svc; do
            busctl --user get-property "$_svc" /StatusNotifierItem \
              org.kde.StatusNotifierItem Id 2>/dev/null |
              sed -n 's/^s "\(.*\)"$/\1/p'
          done
      fi
    } | tr ',' '\n' | sed '/^$/d' | sort -u
  )

  # The declared shown-lists, in panel-then-widget order.
  mapfile -t SHOWN < <(jq -r '[.panels[].widgets[] | select(has("shown"))] | .[] | .shown | join(",")' "$JSON")

  if [ "${#TRAYS[@]}" -ne "${#SHOWN[@]}" ]; then
    log "WARNING: ${#TRAYS[@]} live tray containments but ${#SHOWN[@]} declared — applying the overlap"
  fi

  for i in "${!TRAYS[@]}"; do
    id="${TRAYS[$i]}"
    [ "$i" -lt "${#SHOWN[@]}" ] || { log "tray $((i + 1)) (containment $id): not declared — left alone"; continue; }
    shown="${SHOWN[$i]}"
    hidden=$(printf '%s\n' "$universe" |
      awk -v s=",$shown," 'index(s, "," $0 ",") == 0' | paste -sd,)
    kwriteconfig6 --file "$APPLETS" --group Containments --group "$id" \
      --group General --key shownItems "$shown"
    kwriteconfig6 --file "$APPLETS" --group Containments --group "$id" \
      --group General --key hiddenItems "$hidden"
    # extraItems must carry the plasmoid ids (the dotted ones); plain SNI ids
    # are registered by their apps and must not be listed as applets.
    plasmoids=$(printf '%s\n' "$shown" | tr ',' '\n' | awk '/\./' | paste -sd,)
    kwriteconfig6 --file "$APPLETS" --group Containments --group "$id" \
      --group General --key extraItems "$plasmoids"
    log "tray $((i + 1)) (containment $id): shown=[$shown]"
    log "tray $((i + 1)) (containment $id): hidden=[$hidden]"
  done

  # The systemtray containment reads those keys when it is constructed, so
  # they land on the next plasmashell start. At activation that is fine to
  # force (PANELS_ALLOW_RESTART=1, set only by the HM activation entry point);
  # at login the hash already matches and we never get here at all.
  if [ "${PANELS_ALLOW_RESTART:-0}" = "1" ] && command -v systemctl >/dev/null 2>&1; then
    log "restarting plasmashell so the tray lists take effect"
    systemctl --user restart plasma-plasmashell.service || \
      log "plasmashell restart failed — tray lists apply at next login"
  else
    log "tray lists apply at next plasmashell start"
  fi
fi

mkdir -p "$(dirname "$STATE")"
printf '%s\n' "$cur_hash" > "$STATE"
log "done"
