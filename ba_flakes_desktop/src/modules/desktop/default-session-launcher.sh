#!/usr/bin/env bash
# ============================================================================
# default-session-launcher.sh — DECLARATIVE default 4-desktop login layout.
# ============================================================================
# Reads default-session.json (the DATA / single source of truth) and launches,
# titles, pins-to-desktop and tiles every window described there.
#
# "NEVER HOLDS THE LOGIN" GUARANTEE (data: .fallback in the JSON):
#   * Invoked by a Plasma autostart .desktop — i.e. AFTER the session is up,
#     so it is structurally incapable of blocking the compositor/login.
#   * Every app is spawned DETACHED (setsid, fire-and-forget).
#   * Every wait is BOUNDED (`timeout` / capped poll loops).
#   * Any failure is LOGGED and SKIPPED — the script always exits 0 so it can
#     never mark the graphical session as failed.
#
# This file is the ENGINE. Never hardcode layout here — edit default-session.json.
#
# CLI (for testing):
#   --dry-run         print the launch plan, touch nothing
#   --desktop=N       only act on desktop N (scratch-test one desktop)
#   --no-position     launch + title tabs but skip KWin positioning
# ============================================================================
set -u

# PATH safety net — Plasma autostart may invoke us with a thin PATH (same reason
# build.sh prepends these). The tools we need (konsole, qdbus, jq, dolphin, kate,
# brave, waydroid) live across system + nix-profile.
export PATH="/run/current-system/sw/bin:$HOME/.nix-profile/bin:/run/wrappers/bin:/etc/profiles/per-user/$USER/bin:$PATH"

SELF_DIR="$(dirname "$(readlink -f "$0")")"
JSON="${DEFAULT_SESSION_JSON:-$SELF_DIR/default-session.json}"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/default-session.log"

DRY=0; ONLY_DESKTOP=""; DO_POSITION=1
for a in "$@"; do case "$a" in
  --dry-run)     DRY=1 ;;
  --desktop=*)   ONLY_DESKTOP="${a#*=}" ;;
  --no-position) DO_POSITION=0 ;;
esac; done

mkdir -p "$(dirname "$LOG")"
log(){ printf '%s [default-session] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG" >&2; }

# ── Tooling (never abort the session if something is missing) ──────────────
JQ="$(command -v jq || true)"
QDBUS="$(command -v qdbus6 || command -v qdbus || true)"
[ -n "$JQ" ]    || { log "FATAL: jq not found — aborting (exit 0)";    exit 0; }
[ -r "$JSON" ]  || { log "FATAL: cannot read $JSON — aborting (exit 0)"; exit 0; }
[ -n "$QDBUS" ] || { log "WARN: qdbus not found — will launch without KWin positioning"; DO_POSITION=0; }

q(){ jq -r "$1" "$JSON"; }
TIMEOUT="$(q '.fallback.per_app_launch_timeout_sec // 25')"
POS_PASSES="$(q '.fallback.position_passes // 10')"
POS_INTERVAL="$(q '.fallback.position_interval_sec // 1.5')"
WORKDIR="$HOME"
POSMAP="$(mktemp -t default-session-pos.XXXXXX)"
trap 'rm -f "$POSMAP" "$POSMAP.js" 2>/dev/null' EXIT

# ── KWin helpers ───────────────────────────────────────────────────────────
kwin_eval(){ # $1 = path to .js — load, run, stop (best-effort, bounded)
  local id
  id="$(timeout 10 "$QDBUS" org.kde.KWin /Scripting \
        org.kde.kwin.Scripting.loadScript "$1" "ds_${$}_${RANDOM}" 2>/dev/null)" || return 1
  timeout 10 "$QDBUS" org.kde.KWin /Scripting org.kde.kwin.Scripting.start >/dev/null 2>&1
  sleep 0.6
  timeout 10 "$QDBUS" org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.stop >/dev/null 2>&1
  return 0
}

spawn(){ # spawn detached, echo pid. $@ = argv
  setsid "$@" >/dev/null 2>&1 &
  echo "$!"
}

# ── Konsole window builder (tabs + sticky titles via DBus) ──────────────────
build_konsole(){ # $1=desktop $2=cell $3=di $4=wi $5=exec $6..=konsole_flags
  local desk="$1" cell="$2" di="$3" wi="$4" kexec="$5"; shift 5
  local kflags=("$@") pid ksvc ntabs ti sid idx title
  ntabs="$(jq -r ".desktops[$di].windows[$wi].tabs | length" "$JSON")"
  pid="$(spawn "$kexec" "${kflags[@]}" --workdir "$WORKDIR")"
  ksvc="org.kde.konsole-$pid"
  # wait (bounded) for the new konsole's DBus window to appear
  local ok=0 t
  for t in $(seq 1 $((TIMEOUT*4))); do
    # crash-early fallback: if the konsole process died, stop waiting immediately
    if ! kill -0 "$pid" 2>/dev/null; then
      log "WARN: konsole (pid $pid) exited during startup — skipping (fallback: continue)"; return 0
    fi
    timeout 3 "$QDBUS" "$ksvc" /Windows/1 org.kde.konsole.Window.sessionList >/dev/null 2>&1 && { ok=1; break; }
    sleep 0.25
  done
  [ "$ok" = 1 ] || { log "WARN: konsole (pid $pid) DBus window never appeared in ${TIMEOUT}s — skipping titles"; printf 'pid\t%s\t%s\t%s\n' "$pid" "$desk" "$cell" >>"$POSMAP"; return 0; }
  # ── Build each tab (+ optional per-tab pane splits), then set sticky titles ──
  local KW="$ksvc" WN=/Windows/1
  # leaf view ids = numbers left after stripping the (N) splitter ids
  vleaves(){ timeout 3 "$QDBUS" "$KW" "$WN" org.kde.konsole.Window.viewHierarchy 2>/dev/null | tr '\n' ' ' | command sed -E 's/\([0-9]+\)//g' | command grep -oE '[0-9]+' | sort; }
  slist(){ timeout 3 "$QDBUS" "$KW" "$WN" org.kde.konsole.Window.sessionList 2>/dev/null | sort; }
  onlyin_b(){ comm -13 <(printf '%s\n' $1 | sort -u) <(printf '%s\n' $2 | sort -u); }  # items in $2 not $1

  local nsplit si pane dir hsplit lBefore sBefore newleaf rootView rootSession tabSessions cmd cbin
  for ti in $(seq 0 $((ntabs-1))); do
    # establish this tab's root view + its session(s)
    if [ "$ti" = 0 ]; then
      rootView="$(vleaves | head -1)"
      tabSessions="$(slist | head -1)"
    else
      lBefore="$(vleaves)"; sBefore="$(slist)"
      timeout 3 "$QDBUS" "$KW" "$WN" org.kde.konsole.Window.newSession "" "$WORKDIR" >/dev/null 2>&1 || true
      sleep 0.3
      rootView="$(onlyin_b "$lBefore" "$(vleaves)" | tail -1)"
      tabSessions="$(onlyin_b "$sBefore" "$(slist)")"
    fi
    rootSession="$(printf '%s\n' $tabSessions | command grep -E '^[0-9]+$' | head -1)"
    timeout 3 "$QDBUS" "$KW" "$WN" org.kde.konsole.Window.setCurrentView "$rootView" >/dev/null 2>&1 || true
    # apply declared splits — pane field is a LOCAL index (0=tab root, then creation order)
    nsplit="$(jq -r "(.desktops[$di].windows[$wi].tabs[$ti].splits // []) | length" "$JSON")"
    local -a viewmap=( "$rootView" )
    for si in $(seq 0 $((nsplit-1))); do
      [ "$nsplit" -eq 0 ] && break
      pane="$(jq -r ".desktops[$di].windows[$wi].tabs[$ti].splits[$si].pane // 0" "$JSON")"
      dir="$(jq -r ".desktops[$di].windows[$wi].tabs[$ti].splits[$si].dir // \"tb\"" "$JSON")"
      [ "$dir" = lr ] && hsplit=true || hsplit=false
      lBefore="$(vleaves)"; sBefore="$(slist)"
      timeout 3 "$QDBUS" "$KW" "$WN" org.kde.konsole.Window.createSplit "${viewmap[$pane]:-$rootView}" "$hsplit" >/dev/null 2>&1 || true
      sleep 0.3
      newleaf="$(onlyin_b "$lBefore" "$(vleaves)" | tail -1)"
      viewmap+=( "$newleaf" )
      tabSessions="$tabSessions $(onlyin_b "$sBefore" "$(slist)")"
    done
    # sticky title on EVERY session in this tab (split panes included → label stays put)
    title="$(jq -r ".desktops[$di].windows[$wi].tabs[$ti].title // \"-\"" "$JSON")"
    [ "$title" = "null" ] && title="-"
    for sid in $tabSessions; do
      timeout 3 "$QDBUS" "$KW" "/Sessions/$sid" org.kde.konsole.Session.setTabTitleFormat 0 "$title" >/dev/null 2>&1 || true
    done
    [ "$nsplit" -gt 0 ] && log "  konsole tab '$title': applied $nsplit split(s)"
    # optional per-tab command — run in the tab's root pane; FALLBACK: if the
    # command's binary isn't on PATH, leave the tab as a plain shell (no break).
    cmd="$(jq -r ".desktops[$di].windows[$wi].tabs[$ti].command // empty" "$JSON")"
    if [ -n "$cmd" ]; then
      cbin="${cmd%% *}"
      if command -v "$cbin" >/dev/null 2>&1; then
        timeout 3 "$QDBUS" "$KW" "/Sessions/$rootSession" org.kde.konsole.Session.runCommand "$cmd" >/dev/null 2>&1 || true
        log "  konsole tab '$title': ran '$cmd'"
      else
        log "  konsole tab '$title': command '$cbin' NOT FOUND — left as shell (fallback)"
      fi
    fi
  done
  log "konsole pid=$pid desk=$desk cell=$cell tabs=$ntabs ✓"
  printf 'pid\t%s\t%s\t%s\n' "$pid" "$desk" "$cell" >>"$POSMAP"
}

# ── Generic GUI app (matched for positioning by window class) ───────────────
launch_app(){ # $1=desktop $2=cell $3=class-key $4=app-name $5..=argv
  local desk="$1" cell="$2" cls="$3" name="$4"; shift 4
  spawn "$@" >/dev/null
  log "launched $name desk=$desk cell=$cell (match class=$cls)"
  printf 'class\t%s\t%s\t%s\n' "$cls" "$desk" "$cell" >>"$POSMAP"
}

# ── Main: walk the JSON ─────────────────────────────────────────────────────
ndesk="$(jq '.desktops | length' "$JSON")"
log "start (json=$JSON, dry=$DRY, only=${ONLY_DESKTOP:-all}, timeout=${TIMEOUT}s)"
for di in $(seq 0 $((ndesk-1))); do
  desk="$(jq -r ".desktops[$di].id" "$JSON")"
  [ -n "$ONLY_DESKTOP" ] && [ "$ONLY_DESKTOP" != "$desk" ] && continue
  nwin="$(jq ".desktops[$di].windows | length" "$JSON")"
  for wi in $(seq 0 $((nwin-1))); do
    app="$(jq -r ".desktops[$di].windows[$wi].app" "$JSON")"
    cell="$(jq -r ".desktops[$di].windows[$wi].cell // \"full\"" "$JSON")"
    if [ "$DRY" = 1 ]; then
      log "PLAN desk=$desk cell=$cell app=$app"
      continue
    fi
    # ── Generic, registry-driven dispatch (everything comes from .apps[$app]) ─
    if [ "$(jq -r --arg a "$app" 'has("apps") and (.apps|has($a))' "$JSON")" != "true" ]; then
      log "WARN: app '$app' not in .apps registry — skipped"; continue
    fi
    ax(){ jq -r --arg a "$app" ".apps[\$a].$1 // empty" "$JSON"; }   # registry field
    atype="$(ax type)"; aexec="$(ax exec)"; aclass="$(ax match_class)"; amode="$(ax arg_mode)"
    [ -n "$aexec" ] || aexec="$app"

    # optional launch_prefix (e.g. ["dbus-run-session","--"] to force a NEW instance
    # of a KDBusService single-instance app like systemsettings)
    mapfile -t prefix < <(jq -r --arg a "$app" '.apps[$a].launch_prefix[]? // empty' "$JSON")

    # FALLBACK: app binary (or its launch_prefix tool) not installed → log + skip
    if ! command -v "$aexec" >/dev/null 2>&1; then
      log "SKIP desk=$desk cell=$cell app=$app — exec '$aexec' NOT FOUND on PATH (fallback: continue)"
      continue
    fi
    if [ "${#prefix[@]}" -gt 0 ] && ! command -v "${prefix[0]}" >/dev/null 2>&1; then
      log "WARN desk=$desk cell=$cell app=$app — launch_prefix '${prefix[0]}' NOT FOUND; launching without it"
      prefix=()
    fi

    if [ "$atype" = konsole ]; then
      # konsole flags from registry (default --separate --nofork)
      mapfile -t kflags < <(jq -r --arg a "$app" '.apps[$a].konsole_flags[]? // empty' "$JSON")
      [ "${#kflags[@]}" -gt 0 ] || kflags=(--separate --nofork)
      build_konsole "$desk" "$cell" "$di" "$wi" "$aexec" "${kflags[@]}"
      continue
    fi

    # build argv: [launch_prefix...] exec + fixed_args + per-instance value (path|url|none)
    argv=()
    [ "${#prefix[@]}" -gt 0 ] && argv+=("${prefix[@]}")
    argv+=("$aexec")
    mapfile -t fixed < <(jq -r --arg a "$app" '.apps[$a].fixed_args[]? // empty' "$JSON")
    [ "${#fixed[@]}" -gt 0 ] && argv+=("${fixed[@]}")
    case "$amode" in
      path) v="$(jq -r ".desktops[$di].windows[$wi].args[0] // empty" "$JSON")"; [ -n "$v" ] && argv+=("$v") ;;
      url)  v="$(jq -r ".desktops[$di].windows[$wi].url // empty"     "$JSON")"; [ -n "$v" ] && argv+=("$v") ;;
      paths)
        # multi-tab: append every path that EXISTS as a dir; skip+log missing ones
        # (per-folder fallback — a non-existent folder never breaks the launch).
        added=0
        while IFS= read -r p; do
          [ -z "$p" ] && continue
          if [ -d "$p" ]; then argv+=("$p"); added=$((added+1))
          else log "  ↳ $app: skip missing folder '$p' (fallback)"; fi
        done < <(jq -r ".desktops[$di].windows[$wi].args[]? // empty" "$JSON")
        [ "$added" = 0 ] && log "  ↳ $app: no declared folder exists — opening default window"
        ;;
    esac
    launch_app "$desk" "$cell" "${aclass:-$app}" "$app" "${argv[@]}"
  done
done

[ "$DRY" = 1 ] && { log "dry-run complete"; exit 0; }

# ── Position everything (idempotent; 3 bounded passes to catch slow windows) ─
if [ "$DO_POSITION" = 1 ] && [ -s "$POSMAP" ]; then
  {
    echo 'var byPid={},byClass={};'
    while IFS=$'\t' read -r kind val desk cell; do
      if [ "$kind" = pid ]; then
        printf 'byPid["%s"]={d:%s,cell:"%s"};\n' "$val" "$desk" "$cell"
      else
        printf 'byClass["%s"]={d:%s,cell:"%s"};\n' "$(echo "$val" | tr 'A-Z' 'a-z')" "$desk" "$cell"
      fi
    done <"$POSMAP"
    cat <<'JS'
function deskObj(n){var ds=workspace.desktops;for(var i=0;i<ds.length;i++){if(ds[i].x11DesktopNumber===n)return ds[i];}return null;}
function area(w){var a;try{a=workspace.clientArea(KWin.MaximizeArea,w);}catch(e){a=null;}
  if(!a||!a.width){var s=workspace.virtualScreenSize;a={x:0,y:0,width:s.width,height:s.height};}return a;}
// IMPORTANT: read-modify-write the real frameGeometry QRect. Assigning a plain
// {x,y,width,height} object makes KWin honor size but RE-CENTER position; mutating
// the actual QRect and assigning it back makes x/y stick. (Qt.rect is unavailable.)
function place(w,cell){var a=area(w);var hw=Math.floor(a.width/2);var g=w.frameGeometry;
  if(cell==="left"){g.x=a.x;g.y=a.y;g.width=hw;g.height=a.height;}
  else if(cell==="right"){g.x=a.x+a.width-hw;g.y=a.y;g.width=hw;g.height=a.height;}
  else{g.x=a.x;g.y=a.y;g.width=a.width;g.height=a.height;}
  w.frameGeometry=g;}
var ws=workspace.windowList?workspace.windowList():workspace.clientList();
for(var i=0;i<ws.length;i++){var w=ws[i];if(!w.normalWindow)continue;
  var t=byPid[""+w.pid]||byClass[(""+w.resourceClass).toLowerCase()];if(!t)continue;
  var d=deskObj(t.d);if(d){try{w.desktops=[d];}catch(e){try{w.desktop=t.d;}catch(e2){}}}
  try{place(w,t.cell);}catch(e){}
}
JS
  } >"$POSMAP.js"
  log "positioning ($(grep -c . "$POSMAP") windows, ${POS_PASSES} passes @ ${POS_INTERVAL}s — catches slow-mapping windows) ..."
  for pass in $(seq 1 "$POS_PASSES"); do kwin_eval "$POSMAP.js"; sleep "$POS_INTERVAL"; done
  log "positioning done"
fi

log "complete"
exit 0
