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

# One runner at a time. This binary is triggered from HM activation AND from
# the login autostart, and the journal has both firing in the same second
# (run_all.sh[5314] and [5323] on 2026-08-27 12:40:42). Two concurrent passes
# through the rebuild below both call panels().forEach(p => p.remove()) — the
# destroy/recreate that plasmashell SEGV'd inside on 2026-08-22, leaving the
# desktop with no taskbar. The second arrival waits, then re-reads live state
# and finds the first one's work already done.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/plasma-panels-apply.lock"
flock 9 2>/dev/null || log "no flock — proceeding unserialised"

qd=""
for c in qdbus6 qdbus; do command -v "$c" >/dev/null 2>&1 && { qd="$c"; break; }; done
[ -n "$qd" ] || { log "no qdbus on PATH — nothing to do"; exit 0; }

# kreadconfig6/kwriteconfig6 come from kdePackages.kconfig in this script's
# runtimeInputs, so inside the wrapper they are always here. Run the file
# directly (from a working tree, say) and they are not — and because there is
# no errexit, every tray write then fails silently while the run goes on to
# record success and never retry. That is the same shape as the systray unit
# that never ran for months: the failure had no way to be noticed.
for c in kreadconfig6 kwriteconfig6; do
  command -v "$c" >/dev/null 2>&1 || { log "ERROR: $c not on PATH — refusing to half-apply"; exit 1; }
done

evaluate() {
  "$qd" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$1" 2>&1
}

# ── wait for plasmashell ──────────────────────────────────────────────────
# A function because the tray step restarts plasmashell and has to wait for the
# replacement in exactly the same way.
wait_for_plasmashell() {
  i=0
  while [ "$i" -lt 60 ]; do
    evaluate "print('up')" 2>/dev/null | grep -q up && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

wait_for_plasmashell || { log "plasmashell never answered on D-Bus — giving up"; exit 0; }

# Tray containment ids, ascending = creation order = the order the systemtray
# widgets appear in panels.json. Read twice: once for the gate below, once
# after a rebuild (which mints new ids).
tray_ids() {
  [ -f "$APPLETS" ] || return 0
  awk '
    /^\[Containments\]\[[0-9]+\]$/ { id = gensub(/.*\[([0-9]+)\]$/, "\\1", "g"); next }
    /^plugin=org\.kde\.plasma\.private\.systemtray$/ { if (id != "") print id }
  ' "$APPLETS" | sort -n
}

# ── do we need to do anything? ──────────────────────────────────
want=$(jq '.panels | length' "$JSON")
cur_hash=$(sha256sum "$JSON" | cut -d' ' -f1)
old_hash=$(cat "$STATE" 2>/dev/null || echo "")

# The layout as DECLARED and as LIVE, both as plugin ids in panel-then-widget
# order — the same order the rebuild emits and the tray step matches against,
# so a difference here is exactly a difference that matters.
want_layout=$(jq -r '[.panels[] | [.widgets[].plugin] | join(",")] | join("|")' "$JSON")
live_layout=$(evaluate 'print(panels().map(function (p) { return p.widgets().map(function (w) { return w.type; }).join(","); }).join("|"));' 2>/dev/null | tr -d '\r')

# The tray contents as DECLARED and as LIVE, in the same panel-then-widget
# order — the exact counterpart of the layout comparison above.
#
# 2026-08-27: this comparison is why the tray was wrong for a day. The gate
# used to be (hash && layout) alone, and $STATE records that PANELS.JSON was
# applied — but tray contents live in appletsrc, which plasmashell rewrites on
# its own schedule and which no hash here covers. So the first successful run
# wrote $STATE, and every run after it exited at this line before reaching the
# tray step. When plasmashell later dropped shownItems/hiddenItems (both trays
# had NEITHER key, only plasmashell's own 15-entry stock knownItems/extraItems),
# nothing ever put them back, and Plasma's compiled-in defaults became the
# effective source of truth. A gate must measure everything it guards.
# Geometry as DECLARED and as LIVE. Height is otherwise set ONLY inside the
# rebuild below, and the layout gate suppresses the rebuild whenever the widget
# lists match — so a height that drifts can never come back. 2026-08-27: both
# panels sat at Plasma's default 30 (and floating=true) while panels.json had
# said bottom=70 top=40 floating=false all along, and every run logged
# "nothing to do". Same shape as the tray bug directly below.
want_geom=$(jq -r '[.panels[] | "\(.location)=\(.height),\(.floating),\(.alignment // "center")"] | join("|")' "$JSON")
live_geom=$(evaluate 'print(panels().map(function (p) { return p.location + "=" + p.height + "," + p.floating + "," + p.alignment; }).join("|"));' 2>/dev/null | tr -d '\r')

# Widget CONFIG as DECLARED and as LIVE, addressed panel.widget.group.key.
# Third instance of the same bug as the tray and the geometry: w.writeConfig is
# reached ONLY from the widget-add loop inside the rebuild, and the layout gate
# suppresses the rebuild — so a config value that drifts can never come back.
# 2026-08-27: panels.json listed ten icontasks launchers and the live panel had
# nine, missing exactly waydroid-container-mobile.desktop, with every run
# logging "nothing to do". Widget indices line up with the declaration because
# the layout term above has already established that the plugin sequence does.
# shellcheck disable=SC2016  # jq program: $p/$w are jq vars, must NOT be shell-expanded
CFG_ADDR='[.panels | to_entries[] as $p | $p.value.widgets | to_entries[] as $w
  | (($w.value.config // {}) | to_entries[]) as $g | $g.value | to_entries[]
  | { p: $p.key, w: $w.key, g: $g.key, k: .key, v: .value }]'

want_cfg=$(jq -r "$CFG_ADDR"' | map("\(.p).\(.w).\(.g).\(.k)=" +
  (if (.v | type) == "array" then (.v | join(",")) else (.v | tostring) end)) | join("|")' "$JSON")

# One print, joined in JS. plasmashell's print() does not emit a newline here,
# so N prints arrive as one unsplittable blob — the separator has to be built
# on the JS side or the readback can never be compared to want_cfg.
cfg_read_js=$(jq -r "$CFG_ADDR"' | ["var out = []; var w;"] + map(
  "w = panels()[\(.p)].widgets()[\(.w)];" +
  "\nw.currentConfigGroup = [\(.g | tojson)];" +
  "\nout.push(\("\(.p).\(.w).\(.g).\(.k)=" | tojson) + w.readConfig(\(.k | tojson)));"
) + ["print(out.join(\"|\"));"] | join("\n")' "$JSON")

live_cfg=$(evaluate "$cfg_read_js" 2>/dev/null | tr -d '\r\n')

want_tray=$(jq -r '[.panels[].widgets[] | select(has("shown")) | .shown | join(",")] | join("|")' "$JSON")
live_tray=$(
  for _id in $(tray_ids); do
    kreadconfig6 --file "$APPLETS" --group Containments --group "$_id" \
      --group General --key shownItems
  done | paste -sd'|'
)

if [ "$cur_hash" = "$old_hash" ] &&
   [ "$live_layout" = "$want_layout" ] &&
   [ "$live_geom" = "$want_geom" ] &&
   [ "$live_cfg" = "$want_cfg" ] &&
   [ "$live_tray" = "$want_tray" ]; then
  log "layout, geometry, widget config, tray and definition all match — nothing to do"
  exit 0
fi
[ "$live_tray" = "$want_tray" ] || log "tray contents drifted from the declaration — reapplying"

# NEVER destroy a layout that is already correct. 2026-08-24: on a first run
# the state file does not exist, so the hash gate above could not match and the
# runner rebuilt a layout that already matched the declaration exactly —
# destroying and recreating both panels to arrive at what was already there.
# That is not merely wasted work: destroy/recreate is the operation plasmashell
# SEGV'd inside on 2026-08-22, and the desktop came back with no taskbar. It is
# also what stood between a wrong systray and a fixed one, since the tray step
# lives downstream of it. The safest rebuild is the one that does not happen,
# so the trigger is now the layout itself rather than the presence of a file.
if [ "$live_layout" = "$want_layout" ]; then
  widgets=$(jq '[.panels[].widgets[]] | length' "$JSON")
  log "layout already matches ($want panels, $widgets widgets) — skipping rebuild, applying tray contents only"
else
  log "layout differs from the declaration — rebuilding"
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

  # Verify against the LIVE panels, not against our own loop counter — that is
  # the whole self-heal. A partial apply (the 2026-08-22 plasmashell SEGV
  # mid-evaluateScript is the precedent) must leave the state file unwritten so
  # the next trigger rebuilds, instead of recording success and never retrying,
  # which is exactly how that incident produced a desktop with no taskbar.
  live=$(evaluate "print(panels().reduce(function (a, p) { return a + p.widgetIds.length; }, 0));" 2>/dev/null | tr -dc '0-9')
  [ -n "$live" ] || live=0
  if [ "$live" -ne "$widgets" ]; then
    log "ERROR: $live/$widgets widgets landed — leaving state unset so this retries"
    exit 1
  fi

fi

# ── geometry: set in place, no rebuild ────────────────────────────────────
# Assigning to an existing panel's properties does not destroy it, so this is
# safe to run whether or not the layout was just rebuilt (after a rebuild it is
# a no-op re-assert). It exists as its own step precisely because it must NOT
# require the destroy/recreate that the layout gate is there to avoid.
# It is a FUNCTION because the tray step below restarts plasmashell, and a
# restart discards every panel property plasma has not yet flushed to
# plasmashellrc — that flush is on a deferred timer, so "set it, then restart"
# loses the setting. 2026-08-27 21:48 is the worked example: a switch wrote the
# tray lists, restarted plasmashell, recorded the state hash, and the panels
# came back at plasma default 30px floating instead of the declared 70/40.
# cur_hash matched old_hash from then on, so every later run said "nothing to
# do" over a visibly wrong desktop.
apply_geometry() {
  n=0
  while [ "$n" -lt "$want" ]; do
    js=$(jq -r --argjson n "$n" '.panels[$n] |
      "var p = panels()[\($n)];\nif (p) { p.height = \(.height); p.floating = \(.floating); p.alignment = \(.alignment // "center" | tojson); }"' "$JSON")
    evaluate "$js" >/dev/null
    n=$((n + 1))
  done
  got=$(evaluate 'print(panels().map(function (p) { return p.location + "=" + p.height + "," + p.floating + "," + p.alignment; }).join("|"));' 2>/dev/null | tr -d '\r')
  [ "$got" = "$want_geom" ]
}

if [ "$live_geom" != "$want_geom" ]; then
  log "geometry differs — setting in place"
  log "  live: $live_geom"
  log "  want: $want_geom"
  if ! apply_geometry; then
    log "ERROR: geometry did not take — leaving state unset so this retries"
    log "  got: $got"
    exit 1
  fi
  log "geometry now $got"
fi

# ── widget config: written in place, no rebuild ───────────────────────────
# Same reasoning as the geometry step: writeConfig on a live widget does not
# destroy it, so this deliberately avoids the destroy/recreate the layout gate
# exists to prevent. After a rebuild it is a no-op re-assert.
if [ "$live_cfg" != "$want_cfg" ]; then
  log "widget config differs — writing in place"
  cfg_write_js=$(jq -r "$CFG_ADDR"' | map(
    "var w = panels()[\(.p)].widgets()[\(.w)];" +
    "\nw.currentConfigGroup = [\(.g | tojson)];" +
    "\nw.writeConfig(\(.k | tojson), \(.v | tojson));"
  ) | join("\n")' "$JSON")
  evaluate "$cfg_write_js" >/dev/null
  got=$(evaluate "$cfg_read_js" 2>/dev/null | tr -d '\r\n')
  if [ "$got" != "$want_cfg" ]; then
    log "ERROR: widget config did not take — leaving state unset so this retries"
    log "  want: $want_cfg"
    log "  got:  $got"
    exit 1
  fi
  log "widget config now matches the declaration"
fi

# plasmashell writes appletsrc asynchronously; the tray step below reads it.
sleep 3

# ── tray contents: appletsrc, because the scripting API cannot reach them ──
if [ ! -f "$APPLETS" ]; then
  log "no $APPLETS yet — skipping tray contents"
else
  mapfile -t TRAYS < <(tray_ids)

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
    # knownItems is plasmashell's OWN memory of every id it has ever seen, and
    # an id absent from it is treated as new and defaults to SHOWN regardless of
    # hiddenItems. Left alone it is a second source of truth that outlives any
    # declaration — on this box both trays carried an identical 15-entry stock
    # list nothing here ever asked for. Overwriting it with exactly the set we
    # have an opinion about (shown + hidden, i.e. the universe) leaves Plasma
    # nothing of its own to fall back to.
    kwriteconfig6 --file "$APPLETS" --group Containments --group "$id" \
      --group General --key knownItems "$shown${hidden:+,$hidden}"
    log "tray $((i + 1)) (containment $id): shown=[$shown]"
    log "tray $((i + 1)) (containment $id): hidden=[$hidden]"
  done

  # Read the tray lists back before recording success. kwriteconfig6 reports
  # nothing useful on failure, and the whole point of the state file is that a
  # run which recorded it will not retry — so it must only ever be written for a
  # state that was verified present, never for one that was merely attempted.
  for i in "${!TRAYS[@]}"; do
    [ "$i" -lt "${#SHOWN[@]}" ] || continue
    id="${TRAYS[$i]}"
    got=$(kreadconfig6 --file "$APPLETS" --group Containments --group "$id" \
      --group General --key shownItems 2>/dev/null)
    if [ "$got" != "${SHOWN[$i]}" ]; then
      log "ERROR: tray $((i + 1)) (containment $id) did not take — leaving state unset so this retries"
      log "  wanted: ${SHOWN[$i]}"
      log "  got:    ${got:-<empty>}"
      exit 1
    fi
  done

  # The systemtray containment reads those keys when it is constructed, so
  # they land on the next plasmashell start. At activation that is fine to
  # force (PANELS_ALLOW_RESTART=1, set only by the HM activation entry point);
  # at login the hash already matches and we never get here at all.
  if [ "${PANELS_ALLOW_RESTART:-0}" = "1" ] && command -v systemctl >/dev/null 2>&1; then
    log "restarting plasmashell so the tray lists take effect"
    if systemctl --user restart plasma-plasmashell.service; then
      # The replacement shell restores itself from plasmashellrc, which is why
      # geometry is re-asserted here rather than trusted to survive.
      if wait_for_plasmashell && apply_geometry; then
        log "geometry re-asserted after restart: $got"
      else
        log "ERROR: geometry lost to the restart — leaving state unset so this retries"
        log "  got: ${got:-<no answer>}"
        exit 1
      fi
    else
      log "plasmashell restart failed — tray lists apply at next login"
    fi
  else
    log "tray lists apply at next plasmashell start"
  fi
fi

mkdir -p "$(dirname "$STATE")"
printf '%s\n' "$cur_hash" > "$STATE"
log "done"
