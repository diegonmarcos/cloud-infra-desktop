#!/usr/bin/env bash
# ============================================================================
# default-session-launcher.sh — DECLARATIVE default 5-desktop login layout.
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
# The layout below targets desk5. Placing a window on a desktop that does not
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

# ── Konsole sizing, in CELLS (data: .konsole_cell + .screen_reference) ─────
# Konsole sizes itself in character cells and ignores the pixel geometry KWin
# assigns it. Every window this launcher created settled at exactly its
# profile's TerminalColumns x TerminalRows — 120x60 = 872x1037 — no matter
# which cell it was placed in. Position landed pixel-perfect, so the log
# reported success while desk3's left column overlapped by 324px (two 1037-tall
# windows in 713-tall slots) and the right window fell short of the edge.
#
# Fighting that from the KWin side does not work (see the geometry note in the
# placement script). Asking in the units Konsole accepts does: -p
# TerminalColumns / -p TerminalRows at launch. The cell metrics are measured
# data in the JSON — see ._konsole_cell_doc for the derivation.
#
# floor() throughout: a window a few pixels short of its slot is invisible,
# whereas one a few pixels over re-creates the overlap this exists to fix.
konsole_cells(){ # $1=cell → echoes "COLS ROWS"
  local aw ah cw ch pw ph w h
  aw="$(q '.screen_reference.work_width  // 0')"; ah="$(q '.screen_reference.work_height // 0')"
  cw="$(q '.konsole_cell.cell_w // 0')";          ch="$(q '.konsole_cell.cell_h // 0')"
  pw="$(q '.konsole_cell.pad_w  // 0')";          ph="$(q '.konsole_cell.pad_h  // 0')"
  # Any metric missing → emit nothing, and the caller launches without -p
  # (profile default). Never guess a size from half-known data.
  case "0" in "$aw"|"$ah"|"$cw"|"$ch") return 0 ;; esac
  # THE LAUNCH SIZE IS THE FINAL SIZE. On Wayland the client decides its own
  # size: KWin sends a configure and Konsole answers with the nearest whole
  # number of character cells. Nothing on the compositor side overrides that —
  # not a frameGeometry assignment, not quick-tile, and not the
  # `strictgeometry` ("Obey geometry restrictions") window rule, which is an
  # X11-era hint and was tested here with no effect. So the -p values below are
  # not a hint, they ARE the geometry, and the arithmetic has to be right.
  #
  # A stacked pair therefore has to be sized as a PAIR. Split the total rows
  # that fit, rather than giving each window an independent half and hoping the
  # two quantised results happen to meet — they do not, and the shortfall of
  # each lands as a visible seam between them.
  #
  #   rows that fit in the column, both frames paid for:
  #     total = (height - 2*pad) / cell = (1426 - 62) / 16 = 85
  #     top = ceil(85/2) = 43  ->  43*16 + 31 = 719
  #     bot = 85 - 43   = 42   ->  42*16 + 31 = 703
  #     719 + 703 = 1422 in 1426 — 4px, at the very bottom against the panel.
  #
  # 4px is the true minimum: 16*(r1+r2) = 1364 has no integer solution, so the
  # column cannot be filled exactly by two cell-quantised terminals. What is
  # controllable is WHERE the remainder goes, and it goes to the outer edge.
  local total_rows top_rows
  total_rows=$(( (ah - 2 * ph) / ch ))
  top_rows=$(( (total_rows + 1) / 2 ))
  case "$1" in
    left|right)                w=$((aw / 2)); h=$ah ;;
    left-top|right-top)        w=$((aw / 2)); printf '%s %s\n' "$(( (aw / 2 - pw) / cw ))" "$top_rows"; return 0 ;;
    left-bottom|right-bottom)  w=$((aw / 2)); printf '%s %s\n' "$(( (aw / 2 - pw) / cw ))" "$(( total_rows - top_rows ))"; return 0 ;;
    *)                         w=$aw;         h=$ah ;;
  esac
  printf '%s %s\n' "$(( (w - pw) / cw ))" "$(( (h - ph) / ch ))"
}

# ── Konsole window builder (tabs + sticky titles via DBus) ──────────────────
build_konsole(){ # $1=desktop $2=cell $3=di $4=wi $5=exec $6..=konsole_flags
  local desk="$1" cell="$2" di="$3" wi="$4" kexec="$5"; shift 5
  local kflags=("$@") pid ksvc ntabs ti sid idx title _kc _kr
  ntabs="$(jq -r ".desktops[$di].windows[$wi].tabs | length" "$JSON")"
  # Size in cells, so the window comes up the right size instead of being
  # resized into one it will ignore. Empty (metrics missing) = profile default.
  local -a ksize=()
  read -r _kc _kr <<<"$(konsole_cells "$cell")"
  if [ -n "${_kc:-}" ] && [ -n "${_kr:-}" ] && [ "$_kc" -gt 0 ] && [ "$_kr" -gt 0 ]; then
    ksize=( -p "TerminalColumns=$_kc" -p "TerminalRows=$_kr" )
    log "  konsole cell=$cell → ${_kc}x${_kr} cells"
  else
    log "  konsole cell=$cell → no cell metrics, using profile default size"
  fi
  pid="$(spawn "$kexec" "${kflags[@]}" "${ksize[@]}" --workdir "$WORKDIR")"
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

  local nsplit si pane dir hsplit lBefore sBefore newleaf newsess rootView rootSession tabSessions cmd cbin scmd sbin
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
      newsess="$(onlyin_b "$sBefore" "$(slist)")"
      tabSessions="$tabSessions $newsess"

      # Per-split command. Without this only the tab ROOT pane could run
      # anything (the .command below), so a split window could never be more
      # than one live view plus empty shells — no way to express "atop on top,
      # htop underneath" in one window. Same missing-binary fallback as the tab
      # command: leave the pane as a plain shell rather than break the layout.
      scmd="$(jq -r ".desktops[$di].windows[$wi].tabs[$ti].splits[$si].command // empty" "$JSON")"
      if [ -n "$scmd" ]; then
        sbin="${scmd%% *}"
        if command -v "$sbin" >/dev/null 2>&1; then
          for sid in $newsess; do
            timeout 3 "$QDBUS" "$KW" "/Sessions/$sid" org.kde.konsole.Session.runCommand "$scmd" >/dev/null 2>&1 || true
          done
          log "  konsole split pane $((si+1)): ran '$scmd'"
        else
          log "  konsole split pane $((si+1)): command '$sbin' NOT FOUND — left as shell (fallback)"
        fi
      fi
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

    # Belt to the emptiness guard's braces: for a SINGLE-INSTANCE app, never
    # launch a second copy. Covers a half-built session — an earlier run killed
    # partway, or an app the user started before login finished.
    #
    # This only applies to apps flagged single_instance in the registry, and
    # that flag is the whole point. The old check ran for EVERY app, which is
    # wrong for the ones this layout deliberately opens more than once: desk3
    # wants two Konsole windows while desk1 already has one, and Konsole is
    # launched --separate --nofork precisely so that works.
    #
    # It got away with it because it was also broken. `pgrep -x kate` does not
    # match a running Kate: NixOS wraps the binary, so comm is ".kate-wrapped",
    # truncated by the kernel to ".kate-wrappe". So the guard never fired for
    # any wrapped app — which is exactly why desk3's Konsoles worked, and why
    # re-running desk2 on 2026-08-21 silently opened a SECOND Kate. Fixing the
    # match without adding the flag would have traded that for a desk3 with no
    # terminals; both halves are needed or neither is safe.
    #
    # A false positive costs one window; a false negative costs the pileup this
    # exists to prevent — so the pattern stays loose, just no longer blind.
    if [ "$(jq -r --arg a "$app" '.apps[$a].single_instance // false' "$JSON")" = "true" ]; then
      if printf '%s\n' "$(ps -eo comm= -u "$(id -u)" 2>/dev/null || true)" \
         | grep -qxE "$aexec|\.$aexec-wrapp.*"; then
        # Skip the LAUNCH, not the POSITIONING. The existing window still needs
        # to end up where the layout says, and positioning matches it by window
        # class, which needs no PID from a spawn we are not doing. Without this
        # a window that came up in the wrong place could never be corrected by
        # re-running — which is precisely the case that exposed it: Kate
        # restores itself maximized (katerc: "2304x1536 screen:
        # Window-Maximized=true"), so desk2 showed it full screen while the log
        # said cell=left, and every re-run skipped it and changed nothing.
        if [ -n "$aclass" ] && [ "$aclass" != null ]; then
          printf 'class\t%s\t%s\t%s\n' "$aclass" "$desk" "$cell" >>"$POSMAP"
          log "SKIP launch desk=$desk cell=$cell app=$app — single-instance and already running; will still position it (class=$aclass)"
        else
          log "SKIP desk=$desk cell=$cell app=$app — single-instance and already running, and no match_class to position it by"
        fi
        continue
      fi
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
// GEOMETRY ASSIGNMENT — assign a FRESH literal with exactly four keys.
//
//   w.frameGeometry = {x: X, y: Y, width: W, height: H};
//
// The API documents frameGeometry as the single read-write property for both
// position and size (develop.kde.org/docs/plasma/kwin/api). Two other forms
// look reasonable and both corrupt the result:
//
//   1. Mutating the object frameGeometry returns. The setter is never invoked,
//      so KWin is never told anything changed.
//   2. Object.assign({}, w.frameGeometry), edit, assign back — the form
//      suggested at discuss.kde.org/t/…/17175. The returned object carries
//      EIGHT keys: x,y,width,height,left,right,top,bottom. Copying all of them
//      and editing only y/height leaves left/right/top/bottom describing the
//      OLD rect, and the result is garbage: it produced 1427x992 windows on a
//      1152-wide slot here.
//
// Qt.rect() would be the natural constructor but Qt is undefined in this
// engine (checked: typeof Qt === "undefined"), so a literal it is.
//
// Verified on KWin 6.7.2, 2026-08-21: a clean literal applied 0,40 1152x701
// exactly, position and size in one assignment. Earlier readings that said
// otherwise were contaminated — the launcher's own 10-pass positioning loop
// from a previous invocation was still running and moving the same windows
// during the measurement. Kill any running launcher before testing geometry.
//
// Konsole additionally QUANTISES to whole character cells — asked for 713 it
// takes 701 (39 cells + frame) — so no geometry call can make it fill a slot
// exactly. That is handled at launch instead, by asking in cells: see
// konsole_cells() and .konsole_cell in the JSON. KWin's own quick-tile
// (workspace.slotWindowQuickTile*) does not avoid it either — tested, it
// quantises the same way and then bottom-anchors the remainder, moving the
// leftover gap into the middle of the screen instead of the outer edge.
// Clear maximized/fullscreen BEFORE touching geometry. A maximized window keeps
// its maximized geometry no matter what you assign to frameGeometry, so the tile
// silently did nothing for any app that restores itself maximized. Kate is one:
// ~/.config/katerc carries "2304x1536 screen: Window-Maximized=true", so it came
// up full screen on desk2 while the log cheerfully said cell=left. Both calls are
// wrapped because the API differs across KWin versions and a placement failure
// must never abort the pass.
function unmax(w){
  try{ if(w.fullScreen) w.fullScreen=false; }catch(e){}
  try{ w.setMaximize(false,false); }catch(e){}
}
// Cells: left|right = half width, full height. left-top|left-bottom|
// right-top|right-bottom = quarters. Anything else = full screen.
// Heights use ceil for the top half and derive the bottom from it, so an odd
// pixel height leaves no 1px gap between the two.
function place(w,cell){unmax(w);var a=area(w);var hw=Math.floor(a.width/2);
  var th=Math.ceil(a.height/2);var bh=a.height-th;var rx=a.x+a.width-hw;
  var x,y,ww,hh;
  if(cell==="left"){x=a.x;y=a.y;ww=hw;hh=a.height;}
  else if(cell==="right"){x=rx;y=a.y;ww=hw;hh=a.height;}
  else if(cell==="left-top"){x=a.x;y=a.y;ww=hw;hh=th;}
  else if(cell==="left-bottom"){x=a.x;y=a.y+th;ww=hw;hh=bh;}
  else if(cell==="right-top"){x=rx;y=a.y;ww=hw;hh=th;}
  else if(cell==="right-bottom"){x=rx;y=a.y+th;ww=hw;hh=bh;}
  else{x=a.x;y=a.y;ww=a.width;hh=a.height;}
  setGeom(w,x,y,ww,hh);}
// TWO assignments, in this order, because neither form does both:
//   1. fresh 4-key literal  -> applies SIZE, re-centres x/y on the screen
//   2. mutate what it returns -> applies x/y, ignores size
// Measured on KWin 6.7.2 2026-08-21: literal alone left every window at
// x=576 (dead centre of 2304) with the right size; mutation alone left every
// window pixel-perfect in position at its untouched startup size.
function setGeom(w,x,y,ww,hh){
  w.frameGeometry={x:x,y:y,width:ww,height:hh};
  var p=w.frameGeometry;p.x=x;p.y=y;w.frameGeometry=p;
}
var ws=workspace.windowList?workspace.windowList():workspace.clientList();
var placed=[];
for(var i=0;i<ws.length;i++){var w=ws[i];if(!w.normalWindow)continue;
  var t=byPid[""+w.pid]||byClass[(""+w.resourceClass).toLowerCase()];if(!t)continue;
  var d=deskObj(t.d);if(d){try{w.desktops=[d];}catch(e){try{w.desktop=t.d;}catch(e2){}}}
  try{place(w,t.cell);}catch(e){}
  placed.push({w:w,t:t});
}
// SEAM PASS — butt each *-bottom window against the ACTUAL bottom edge of the
// *-top window above it, instead of the ideal midpoint.
//
// The two never agree: a terminal quantises to whole character cells, so a
// window asked for 713 takes 701 and the 12px it declined shows up as a gap
// between the two windows. Computing the slot cannot fix that, because the
// launcher does not know what the client will accept until it has accepted it.
// Reading the real geometry back does, and it works for any client that
// quantises for any reason — not just Konsole, and with no font metrics.
//
// Runs inside the same repeating pass as everything else, so it re-converges
// as slow windows map and settle.
for(var j=0;j<placed.length;j++){
  var b=placed[j];var col=null;
  if(b.t.cell==="left-bottom")col="left-top";
  else if(b.t.cell==="right-bottom")col="right-top";
  if(!col)continue;
  for(var k=0;k<placed.length;k++){
    var a2=placed[k];
    if(a2.t.cell!==col||a2.t.d!==b.t.d)continue;
    var top=a2.w.frameGeometry, area2=area(b.w), cur=b.w.frameGeometry;
    var y=top.y+top.height;
    var h=area2.y+area2.height-y;
    if(h<=0)break;
    setGeom(b.w,top.x,y,cur.width,h);
    break;
  }
}
JS
  } >"$POSMAP.js"
  log "positioning ($(grep -c . "$POSMAP") windows, ${POS_PASSES} passes @ ${POS_INTERVAL}s — catches slow-mapping windows) ..."
  for pass in $(seq 1 "$POS_PASSES"); do kwin_eval "$POSMAP.js"; sleep "$POS_INTERVAL"; done
  log "positioning done"
fi

log "complete"
exit 0
