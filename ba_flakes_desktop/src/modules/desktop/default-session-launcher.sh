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
#   --force           bypass the emptiness guard (MANUAL use only — it is what
#                     stops duplication at login, so forcing on a populated
#                     desktop is how you get two of everything). Pair it with
#                     --desktop=N to fill in just the desktop that is missing.
# ============================================================================
set -u

# PATH safety net — Plasma autostart may invoke us with a thin PATH (same reason
# build.sh prepends these). The tools we need (konsole, qdbus, jq, dolphin, kate,
# brave, waydroid) live across system + nix-profile.
#
# /run/wrappers/bin MUST come first. It used to sit third, behind
# /run/current-system/sw/bin, and because this launcher starts the whole desktop
# session every process inherited that order. The result: `sudo` resolved to
# /run/current-system/sw/bin/sudo (the plain package binary, not setuid) and
# every invocation died with "must be owned by uid 0 and have the setuid bit
# set" — 2026-08-11, hit while trying to delete btrfs snapshots. This is not a
# sudo-specific bug: /run/wrappers/bin holds EVERY setuid wrapper (sudo, mount,
# ping, pkexec, fusermount), so anything shadowed there fails the same way.
# Wrappers first is the NixOS default ordering for exactly this reason.
export PATH="/run/wrappers/bin:/run/current-system/sw/bin:$HOME/.nix-profile/bin:/etc/profiles/per-user/$USER/bin:$PATH"

SELF_DIR="$(dirname "$(readlink -f "$0")")"
JSON="${DEFAULT_SESSION_JSON:-$SELF_DIR/default-session.json}"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/default-session.log"

DRY=0; ONLY_DESKTOP=""; DO_POSITION=1; FORCE=0
for a in "$@"; do case "$a" in
  --dry-run)     DRY=1 ;;
  --desktop=*)   ONLY_DESKTOP="${a#*=}" ;;
  --no-position) DO_POSITION=0 ;;
  --force)       FORCE=1 ;;
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

# ── Concurrency lock ────────────────────────────────────────────────────────
# Stops CONCURRENT invocations. This is not the duplication guard — it is only
# a race guard, and it was doing the duplication guard's job for months (86
# blocked runs against 129 that got through). The real guard is emptiness,
# below.
RUNDIR="${XDG_RUNTIME_DIR:-/tmp}"
exec 9>"$RUNDIR/default-session.lock" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || { log "another instance holds the lock — this one exits (fallback: no duplicate layout)"; exit 0; }
fi

# ── Emptiness guard ─────────────────────────────────────────────────────────
# THE gate. Apply the default layout only when there is nothing here to
# disturb. Everything this replaces was a proxy for that question, and every
# proxy answered it wrong:
#
#   run_on=fresh_only tested `noresume` on /proc/cmdline — a per-BOOT signal
#   answering a per-SESSION question, and worse, it tested which rEFInd entry
#   was chosen rather than what the kernel did. Booting "NixOS - Primary" with
#   no hibernation image on disk cold-boots into a genuinely fresh session,
#   and the gate skipped it. Verified 2026-08-21: cmdline carried
#   resume=/dev/disk/by-label/Shared-Lib, the kernel loaded 0 hibernation
#   images, session start 11:31:21 matched boot 11:31:30 — a fresh session
#   that got no layout. That case was documented as a "rare cold-fall-through";
#   it is every Primary boot that did not hibernate.
#
#   The $XDG_RUNTIME_DIR stamp had the opposite failure: it blocked a genuine
#   fresh login that happened to be the second session of one boot.
#
# Note what does NOT need handling: a real hibernate resume restores the
# session from the RAM image, so ksmserver never restarts and this script is
# never invoked. Case "restore from snapshot" is correct by construction and
# needs no code — which is why the boot-type gate could only ever produce
# false negatives.
#
# Asking about processes rather than windows is deliberate: it needs no KWin
# script injection, works before any window has mapped, and a running app is
# what would actually be duplicated.
# Match the NixOS wrapper name too. `pgrep -x konsole` does NOT match a running
# Konsole here: the binary on PATH is a wrapper, so comm is ".konsole-wrapped",
# and comm is truncated to 15 characters, making it ".konsole-wrappe" — which is
# why the pattern ends open rather than at "-wrapped". Checked live: brave runs
# as both "brave" and ".brave-wrapped", my-konsole as itself, Konsole ONLY as
# the truncated wrapper. Matching just the plain name would have reported an
# empty desktop with Konsole plainly open, and duplicated the whole layout on
# top of it — the exact failure this guard exists to prevent.
_procs="$(ps -eo comm= -u "$(id -u)" 2>/dev/null || true)"
_running=""
for _a in $(q '[.desktops[].windows[].app] | unique | .[]'); do
  if printf '%s\n' "$_procs" | grep -qxE "$_a|\.$_a-wrapp.*"; then
    _running="${_running:+$_running }$_a"
  fi
done
if [ -n "$_running" ] && [ "$FORCE" = 0 ]; then
  log "desktop is not empty (already running: $_running) — skipping default layout"
  exit 0
fi
if [ -n "$_running" ]; then
  log "FORCED past the emptiness guard (already running: $_running) — expect duplicates unless --desktop=N narrows this"
else
  log "desktop is empty — applying default layout"
fi

# ── Ensure the virtual desktops exist (data: .virtual_desktops) ─────────────
# The layout below targets desk4. Placing a window on a desktop that does not
# exist lands it wherever KWin likes, which reads as "the layout is broken"
# rather than "a desktop is missing" — so this is checked before any app is
# spawned, not after.
#
# plasma.nix declares the same count from the same JSON key, so this is not a
# second source of truth, it is the runtime half of one. It exists because
# kwinrc is precisely the class of file KWin rewrites from its own in-memory
# state — the same failure that wiped the systray lists out of appletsrc — so a
# value written only at switch time can be undone before the next switch.
#
# Interface verified against the running KWin (6.7.2):
#   property read uint  org.kde.KWin.VirtualDesktopManager.count
#   method void         ...createDesktop(uint position, QString name)
# Every call is best-effort: a missing qdbus or an unresponsive KWin must not
# stop the layout, per the never-block-login contract.
_qdbus=""
for _c in qdbus6 qdbus; do command -v "$_c" >/dev/null 2>&1 && { _qdbus="$_c"; break; }; done
if [ -n "$_qdbus" ]; then
  _want="$(q '.virtual_desktops.count // 0')"
  _have="$("$_qdbus" org.kde.KWin /VirtualDesktopManager count 2>/dev/null || echo 0)"
  case "$_want$_have" in
    *[!0-9]*) log "desktop count unreadable (want='$_want' have='$_have') — continuing" ;;
    *)
      if [ "$_have" -lt "$_want" ]; then
        log "only $_have virtual desktop(s), layout needs $_want — creating the missing ones"
        _i="$_have"
        while [ "$_i" -lt "$_want" ]; do
          _name="$(q ".virtual_desktops.names[$_i] // empty")"
          [ -n "$_name" ] || _name="Desk$((_i + 1))"
          "$_qdbus" org.kde.KWin /VirtualDesktopManager createDesktop "$_i" "$_name" >/dev/null 2>&1 \
            || log "could not create desktop $((_i + 1)) ($_name) — continuing"
          _i=$((_i + 1))
        done
        log "virtual desktops now: $("$_qdbus" org.kde.KWin /VirtualDesktopManager count 2>/dev/null || echo '?')"
      else
        log "virtual desktops: $_have (layout needs $_want) — nothing to create"
      fi
      ;;
  esac
else
  log "no qdbus — cannot verify virtual desktop count, continuing"
fi

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
  # 9>&- is load-bearing. fd 9 is the flock this script holds, and bash does not
  # set close-on-exec on it, so without this every launched app INHERITS the
  # lock and holds it for as long as it lives — Dolphin, Brave, and every shell
  # they spawn. Verified 2026-08-21 by walking /proc/*/fd: after one run the
  # lock was held by .dolphin-wrappe, .brave-wrapped, brave, fish and two cats,
  # long after this script had exited.
  #
  # The effect is that the launcher can never run a second time until every app
  # from the first run has quit. At login that is invisible, because one run is
  # all you want — which is exactly why it survived: it inflates the "another
  # instance holds the lock" count with runs that were never concurrent at all,
  # and makes any manual re-run silently a no-op.
  setsid "$@" >/dev/null 2>&1 9>&- &
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

    # Belt to the run-once guard's braces: never launch a second copy of an app
    # that is already running. The lock and stamp cover the normal duplication
    # path, but they cannot help a session that was half-built (an earlier run
    # killed partway, or an app the user started themselves before login
    # finished). Matching on the exec name is deliberately loose — the cost of a
    # false positive is one window not opening, the cost of a false negative is
    # the pileup this whole guard exists to prevent.
    if pgrep -x "$aexec" >/dev/null 2>&1; then
      log "SKIP desk=$desk cell=$cell app=$app — already running (fallback: no duplicate window)"
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
      urls)
        # multi-tab browser: append every URL in .urls[] as a positional arg
        # (qutebrowser/brave/etc open one tab per URL). No existence check — URLs
        # are remote; an unreachable one just yields an error tab, never breaks launch.
        while IFS= read -r u; do [ -n "$u" ] && argv+=("$u"); done \
          < <(jq -r ".desktops[$di].windows[$wi].urls[]? // empty" "$JSON") ;;
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
