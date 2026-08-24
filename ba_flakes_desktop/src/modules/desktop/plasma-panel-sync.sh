# Single owner of plasma-org.kde.plasma.desktop-appletsrc reconciliation.
#
# WHY THIS EXISTS — three writers, wrong order, silent loss.
#
# Until 2026-08-22 the panel layout and the tray contents were written by two
# independent mechanisms that never agreed on when they ran:
#
#   1. plasma-manager's generated ~/.local/share/plasma-manager/scripts/
#      2_desktop_script_panels.sh, run from run_all.sh AFTER plasmashell is up.
#      It destroys every panel (`panels().forEach(p => p.remove())`) and rebuilds
#      them, so the systemtray containments are DELETED AND REALLOCATED with
#      fresh ids and Plasma's stock defaults.
#   2. plasma-systray-config.service, ordered Before=plasma-plasmashell.service,
#      which discovers the systemtray containment ids from appletsrc and writes
#      the declared shown/hidden lists into them.
#
# (2) therefore always ran against the ids of the PREVIOUS layout, and (1) then
# threw those containments away. Proof from 2026-08-22: the tray applier wrote
# containments 7915/7927 at 17:19:26; after the next boot the layout script had
# rebuilt them as 8206/8217, and the trays came up on stock defaults with no
# hiddenItems= line at all. Nothing logged an error — the applier succeeded, its
# output was simply deleted afterwards.
#
# Worse, (1) deletes appletsrc from the shell BEFORE calling evaluateScript:
#
#   [ -f .../plasma-org.kde.plasma.desktop-appletsrc ] && rm .../plasma-org...
#   qdbus org.kde.plasmashell /PlasmaShell ...evaluateScript "$(cat ...panels.js)"
#
# so panel.remove() writes into a KConfigGroup whose backing file is gone. That
# SEGV'd plasmashell at 18:07:26 (KConfigGroup::config -> writeEntry <-
# AppletPrivate::setDestroyed <- Applet::destroy <- Panel::qt_metacall) and cost
# the bottom panel entirely. Its `trap 'success=0' ERR` never fires in POSIX sh
# and qdbus exits 0 on an aborted script, so the crash was recorded as a success
# in last_run_desktop_script_panels and never retried.
#
# THE FIX: one pipeline, one order, after plasmashell, verified.
#
#   layout (if drifted)  ->  widget repair  ->  tray lists  ->  marker
#
# The layout is applied by evaluating plasma-manager's OWN generated JS — it
# stays the single source of truth for what the panels contain — but WITHOUT the
# rm, which is the only part that crashes. plasma-manager's script is then
# neutralised by seeding its marker, so it can never run its destructive path.
# Because the tray applier now runs last and discovers ids live, it can no
# longer be invalidated by a rebuild happening after it.
#
# Env (set by the caller, so nothing is Nix-interpolated into this file — same
# convention as plasma-systray-config.sh / plasma-fix-missing-panel-widgets.sh):
#   PANEL_REPAIR_BIN   plasma-fix-missing-panel-widgets
#   SYSTRAY_CONFIG_BIN plasma-systray-config

set -u

PM_DIR="$HOME/.local/share/plasma-manager"
LAYOUT_JS="$PM_DIR/data/desktop_script_panels.js"
MARKER="$PM_DIR/last_run_desktop_script_panels"

log() { echo "[panel-sync] $*"; }

qd=""
for c in qdbus6 qdbus; do command -v "$c" >/dev/null 2>&1 && { qd="$c"; break; }; done
if [ -z "$qd" ]; then log "no qdbus on PATH — nothing to do"; exit 0; fi

evaluate() {
  "$qd" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$1" 2>&1
}

# ── 0. wait for plasmashell ────────────────────────────────────────────────
# Ordered After=plasma-plasmashell.service, but systemd considers a simple
# service started as soon as it forks — the D-Bus interface lands later.
i=0
while [ "$i" -lt 60 ]; do
  evaluate "print('up')" 2>/dev/null | grep -q up && break
  i=$((i + 1))
  sleep 1
done
if [ "$i" -ge 60 ]; then log "plasmashell never answered on D-Bus — giving up"; exit 0; fi

# ── 1. layout ──────────────────────────────────────────────────────────────
if [ ! -f "$LAYOUT_JS" ]; then
  log "no generated layout at $LAYOUT_JS — skipping layout step"
else
  # Declared count comes from the generated JS itself, so there is no second
  # place to keep in sync with bottom-panel.nix / top-panel.nix.
  want=$(grep -c 'new Panel()' "$LAYOUT_JS" 2>/dev/null || echo 0)
  have=$(evaluate "print(panels().length)" 2>/dev/null | tr -dc '0-9')
  [ -n "$have" ] || have=0

  # Two independent reasons to re-apply, and BOTH are needed:
  #   - count drift      : a panel was lost (the SEGV case)
  #   - marker mismatch  : the generation changed the declared widgets. The
  #                        panel COUNT is unchanged in that case, so a
  #                        count-only check would silently skip the new layout
  #                        and then seed the marker, stranding the old widgets
  #                        forever. This is the same class of bug as the
  #                        write-marker-on-failure one below.
  cur_hash=$(sha256sum "$LAYOUT_JS")
  old_hash=$(cat "$MARKER" 2>/dev/null || echo "")

  if [ "$have" -ne "$want" ] || [ "$cur_hash" != "$old_hash" ]; then
    log "panels: have $have, declared $want, marker $([ "$cur_hash" = "$old_hash" ] && echo current || echo stale) — re-applying layout (no rm; see header)"
    out=$(evaluate "$(cat "$LAYOUT_JS")")
    [ -n "$out" ] && log "layout output: $out"
    sleep 2
    have=$(evaluate "print(panels().length)" 2>/dev/null | tr -dc '0-9')
    [ -n "$have" ] || have=0
    if [ "$have" -ne "$want" ]; then
      # Do NOT seed the marker: leaving it unset is what lets the next login
      # retry instead of recording a failure as success, which is the exact
      # bug this file exists to remove.
      log "ERROR: layout still $have/$want after re-apply — marker left unset so this retries"
      exit 1
    fi
    log "panels: $have/$want"
  else
    log "panels: $have/$want — no layout change needed"
  fi
fi

# ── 2. widget repair ───────────────────────────────────────────────────────
# Add-back for the watchdog applets plasmashell's script engine drops past the
# second instance of a plugin id. Must run after the layout: it repairs into
# whatever panels currently exist.
if [ -n "${PANEL_REPAIR_BIN:-}" ] && [ -x "$PANEL_REPAIR_BIN" ]; then
  "$PANEL_REPAIR_BIN" || log "widget repair returned non-zero — continuing"
else
  log "PANEL_REPAIR_BIN unset or not executable — skipped"
fi

# ── 3. tray lists ──────────────────────────────────────────────────────────
# Last, because it is the step whose output the layout rebuild used to delete.
# It discovers the systemtray containment ids from appletsrc at run time, so it
# is correct for whatever ids step 1 just allocated.
if [ -n "${SYSTRAY_CONFIG_BIN:-}" ] && [ -x "$SYSTRAY_CONFIG_BIN" ]; then
  "$SYSTRAY_CONFIG_BIN" || log "systray config returned non-zero — continuing"
else
  log "SYSTRAY_CONFIG_BIN unset or not executable — skipped"
fi

# ── 4. neutralise plasma-manager's destructive script ──────────────────────
# Seeding the marker with the current hash makes 2_desktop_script_panels.sh a
# no-op, so its `rm appletsrc` + evaluateScript path — the one that SEGV'd
# plasmashell and lost the bottom panel — can never run. Only reached once the
# layout above has been verified, so the marker means "applied", not "attempted".
if [ -f "$LAYOUT_JS" ]; then
  mkdir -p "$PM_DIR"
  sha256sum "$LAYOUT_JS" > "$MARKER"
fi

log "done"
