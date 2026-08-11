#!/usr/bin/env bash
# freeze-guard.sh — layer 3: active PSI killer in the untouchable island.
#
# Fully runtime-data-driven: ALL thresholds, cgroup slice names, the
# prefer/avoid/hard_protect/soft_avoid regexes, sustain windows, write-storm
# limits and the comm→unit RESET map are read from CONFIG_JSON
# (/etc/cloud-data/system-protection.json) via jq. Nothing is baked in by
# Nix. See configuration_system-protection.nix for how this script is wired
# (writeShellApplication + environment.etc deploy of the JSON) and
# cloud-data-system-protection.json[.watchdog] for the config + rationale.
#
# Built via pkgs.writeShellApplication — runtimeInputs supplies coreutils,
# procps, gnugrep, gawk, systemd, sudo, jq.
set -u

CONFIG_JSON="${SYSTEM_PROTECTION_JSON:-/etc/cloud-data/system-protection.json}"

# Fail LOUDLY and safely if config is missing/unreadable/unparseable — a
# watchdog that reads no config must never conclude "everything is fine".
if [ ! -r "$CONFIG_JSON" ]; then
  logger -t freeze-guard -p user.err "freeze-guard: CONFIG MISSING/UNREADABLE at $CONFIG_JSON — refusing to run with no thresholds"
  echo "[freeze-guard] FATAL: config missing/unreadable at $CONFIG_JSON" >&2
  exit 1
fi
if ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t freeze-guard -p user.err "freeze-guard: CONFIG UNPARSEABLE at $CONFIG_JSON — refusing to run with no thresholds"
  echo "[freeze-guard] FATAL: config unparseable at $CONFIG_JSON" >&2
  exit 1
fi

MEM_LIMIT=$(jq -r '.watchdog.mem_pressure_full_avg10' "$CONFIG_JSON")
# Alert-only rungs, as percentages of each PSI limit, crossed before any kill.
# Empty = no early warning (the old silence-then-SIGKILL behaviour).
PSI_LADDER_PCT=$(jq -r '(.watchdog.alert_ladder_pct // []) | join(" ")' "$CONFIG_JSON")
PSI_ALERT_REARM_SEC=$(jq -r '.watchdog.alert_rearm_sec // 300' "$CONFIG_JSON")
PSI_NTFY_TOPIC=$(jq -r '.watchdog.ntfy_topic // "diegonmarcos-infra"' "$CONFIG_JSON")
IO_LIMIT=$(jq -r '.watchdog.io_pressure_full_avg10' "$CONFIG_JSON")
CPU_LIMIT=$(jq -r '.watchdog.cpu_pressure_some_avg10' "$CONFIG_JSON")
MAX_KILLS=$(jq -r '.watchdog.max_kills_per_tick' "$CONFIG_JSON")
INTERVAL=$(jq -r '.watchdog.interval_sec' "$CONFIG_JSON")
PREFER=$(jq -r '(.watchdog.prefer_kill // []) | join("|")' "$CONFIG_JSON")
AVOID=$(jq -r '.watchdog.avoid_kill' "$CONFIG_JSON")
# ── two-tier protect (2026-07-26, root cause of the 14:09 freeze) ─────
# hard_protect = NEVER a victim, no matter what (session+debug island).
# soft_avoid = PREFERENCE not an absolute veto: pick_cgroup_victim tries
# non-soft_avoid first, but falls back to the largest-RSS soft_avoid
# process rather than doing nothing (the old AVOID veto covered EVERY
# candidate in the throttled slice → "no eligible victim ... cannot act"
# → zero kills → froze).
HARD_PROTECT=$(jq -r '.watchdog.hard_protect' "$CONFIG_JSON")
SOFT_AVOID=$(jq -r '.watchdog.soft_avoid' "$CONFIG_JSON")
# ── memory.high-THRASH voter (v3, 2026-07-10) ──────────────────────────
# The 13:06 freeze was INVISIBLE to PSI (memory.pressure ~35%, below every
# limit) yet user-1000.slice hit memory.high 1.14M times reclaim-thrashing.
# This voter watches the memory.events 'high' counter delta on the throttled
# slice directly; sustained > HIGH_MAX/s for THRASH_SUSTAIN s → SIGKILL the
# biggest-RSS process INSIDE that slice (cgroup.procs), never systemwide.
THRASH_SLICE=$(jq -r '.watchdog.thrash_slice' "$CONFIG_JSON")
THRASH_CG="/sys/fs/cgroup/${THRASH_SLICE}"
HIGH_MAX=$(jq -r '.watchdog.high_events_per_sec_max' "$CONFIG_JSON")
THRASH_SUSTAIN=$(jq -r '.watchdog.thrash_sustain_sec' "$CONFIG_JSON")
# ── per-slice PSI voter (v3.1, 2026-07-10) — the 15:29 freeze root cause ──
# freeze-guard read GLOBAL /proc/pressure/io (=0.14%) and stayed blind while
# the DESKTOP slice's own io.pressure was 96%/56% (IO-starved by a bulk
# writer). A freeze is per-slice; watch the desktop slice's OWN pressure.
WATCH_SLICE=$(jq -r '.watchdog.watch_slice' "$CONFIG_JSON")
WATCH_CG="/sys/fs/cgroup/${WATCH_SLICE}"
SLICE_IO_LIMIT=$(jq -r '.watchdog.slice_io_full_avg10' "$CONFIG_JSON")
SLICE_MEM_LIMIT=$(jq -r '.watchdog.slice_mem_full_avg10' "$CONFIG_JSON")
HOG_CGS=$(jq -r '(.watchdog.hog_slices // []) | map("/sys/fs/cgroup/" + .) | join(" ")' "$CONFIG_JSON")
KTHREAD_RE=$(jq -r '.watchdog.kthread_comm_re' "$CONFIG_JSON")
# ── write-storm voter (v3.2) — the LEADING indicator PSI misses ─────────
WS_MBPS=$(jq -r '.watchdog.write_storm_mb_per_sec' "$CONFIG_JSON")
WS_DIRTY_MB=$(jq -r '.watchdog.dirty_mb_max' "$CONFIG_JSON")
WS_SUSTAIN=$(jq -r '.watchdog.write_storm_sustain_sec' "$CONFIG_JSON")
WS_DISK=$(jq -r '.watchdog.write_storm_disk' "$CONFIG_JSON")
# ── RESET map (2026-07-26) — comm → systemd unit to restart after a kill ──
# Some victims are systemd-managed daemons (nix-daemon, the compositor)
# whose death should be a fresh RESTART, not a permanent kill — e.g. a
# SIGKILLed nix-daemon otherwise leaves `nix build`/home-manager broken
# until next boot. Data-driven from CONFIG_JSON's watchdog.reset_units, read
# at RUNTIME via jq into a bash associative array (Nix no longer bakes this
# in — the JSON is the sole source of truth, matching every other value here).
declare -A RESET_UNITS=()
while IFS=$'\t' read -r _comm _unit; do
  [ -n "$_comm" ] || continue
  RESET_UNITS["$_comm"]="$_unit"
done < <(jq -r '.watchdog.reset_units // {} | to_entries[] | "\(.key)\t\(.value)"' "$CONFIG_JSON")

# Disk write rate (MB/s) since the last call: field 10 of /proc/diskstats
# (sectors written) * 512, delta / interval. Global writeback view — the
# burst that fills dirty page cache before any PSI stall registers.
disk_write_mbps() {
  local now sec
  sec=$(awk -v d="$WS_DISK" '$3==d {print $10; exit}' /proc/diskstats 2>/dev/null)
  sec=${sec:-0}
  now=$sec
  if [ -n "$PREV_WSEC" ]; then
    echo $(( (now - PREV_WSEC) * 512 / 1024 / 1024 / (INTERVAL>0?INTERVAL:1) ))
  else echo 0; fi
  PREV_WSEC=$now
}
# Dirty + Writeback pages (MB) — the backlog that triggers synchronous
# forced writeback (the stall) once it crosses vm.dirty_ratio.
dirty_mb() {
  awk '/^Dirty:/{d=$2} /^Writeback:/{w=$2} END{print int((d+w)/1024)}' /proc/meminfo 2>/dev/null
}
# Top disk WRITER by /proc/PID/io write_bytes DELTA (bytes written since
# last tick). Persistent map PREV_WB[pid]. Skips kthreads + avoid_kill.
# Prints "pid mbdelta comm".
pick_top_writer() {
  local p wb comm best_pid="" best_d=-1 best_comm="" d
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    [ "$p" -gt 1 ] 2>/dev/null || continue
    wb=$(awk '/^write_bytes:/{print $2}' "/proc/$p/io" 2>/dev/null) || continue
    [ -n "$wb" ] || continue
    d=$(( wb - ${PREV_WB[$p]:-$wb} ))
    PREV_WB[$p]=$wb
    [ "$d" -gt "$best_d" ] || continue
    is_kthread "$p" && continue
    comm=$(cat "/proc/$p/comm" 2>/dev/null) || continue
    echo "$comm" | grep -Eq -- "$AVOID" && continue
    best_d=$d; best_pid=$p; best_comm=$comm
  done
  [ -n "$best_pid" ] && echo "$best_pid $((best_d/1024/1024)) $best_comm"
}

# $2 = "full" (mem/io: all tasks stalled) or "some" (cpu: any task stalled).
psi_avg10() {
  awk -v k="$2" '$1 == k { for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) { sub(/avg10=/,"",$i); print $i } }' "/proc/pressure/$1" 2>/dev/null
}

# Per-slice PSI: read a cgroup's OWN {io,memory,cpu}.pressure file.
# $1 = cgroup dir, $2 = io|memory|cpu, $3 = full|some.
psi_slice_avg10() {
  awk -v k="$3" '$1 == k { for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) { sub(/avg10=/,"",$i); print $i } }' "$1/$2.pressure" 2>/dev/null
}

# A pid is a kernel thread (never killable, never a valid victim) if its
# comm matches KTHREAD_RE or it has zero RSS. The 15:29 guard wasted ticks
# SIGKILLing kworker/thermald while the real IO hog kept running.
is_kthread() {
  local c r
  c=$(cat "/proc/$1/comm" 2>/dev/null) || return 0
  echo "$c" | grep -Eq -- "$KTHREAD_RE" && return 0
  r=$(awk '/^VmRSS:/ {print $2}' "/proc/$1/status" 2>/dev/null)
  [ -z "$r" ] || [ "$r" -eq 0 ] 2>/dev/null
}

# Largest-RSS non-kthread, non-avoid victim across the HOG slices (the bulk
# writers/CPU hogs that starve the desktop). Used when the DESKTOP slice is
# starved but global PSI is low — the culprit is elsewhere, not the desktop.
pick_hog_victim() {
  local cg p comm rss best_pid="" best_rss=-1 best_comm=""
  for cg in $HOG_CGS; do
    [ -r "$cg/cgroup.procs" ] || continue
    while read -r p; do
      if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -le 1 ]; then continue; fi
      is_kthread "$p" && continue
      comm=$(cat "/proc/$p/comm" 2>/dev/null) || continue
      echo "$comm" | grep -Eq -- "$AVOID" && continue
      rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$p/status" 2>/dev/null)
      [ -n "$rss" ] || continue
      if [ "$rss" -gt "$best_rss" ]; then best_rss="$rss"; best_pid="$p"; best_comm="$comm"; fi
    done < "$cg/cgroup.procs"
  done
  [ -n "$best_pid" ] && echo "$best_pid $best_rss $best_comm"
}

# Pick the top offender by $1 sort key (rss or pcpu), skipping already-killed
# pids ($2 = space-separated exclusion list). prefer_kill first, then any
# non-avoid_kill process. Prints "pid metric comm".
pick_victim() {
  local key="$1" skip="$2" excl=""
  [ -n "$skip" ] && excl="^($(echo "$skip" | tr ' ' '|')) "
  # `ps comm=` renders kernel threads with their kworker/ksoftirqd/... name;
  # KTHREAD_RE strips them so the guard never wastes a kill on an unkillable
  # kernel thread (the 15:29 kworker/thermald flailing). AVOID protects the
  # compositor/session essentials.
  local cmd="ps -eo pid=,$key=,comm= --sort=-$key"
  local line
  line=$($cmd | grep -E -- "$PREFER" | grep -E -v -- "$AVOID" | grep -E -v -- "$KTHREAD_RE" | { if [ -n "$excl" ]; then grep -E -v -- "$excl"; else cat; fi; } | head -n1)
  [ -z "$line" ] && line=$($cmd | grep -E -v -- "$AVOID" | grep -E -v -- "$KTHREAD_RE" | { if [ -n "$excl" ]; then grep -E -v -- "$excl"; else cat; fi; } | head -n1)
  echo "$line"
}

# Largest-RSS pid INSIDE the throttled cgroup (thrash voter target). Reads
# the slice's own cgroup.procs — so the runaway that is actually filling
# user-1000.slice is killed, never an innocent process elsewhere.
# TWO-TIER (2026-07-26): pass 1 excludes hard_protect AND soft_avoid
# (preferred victim); if that yields nothing, pass 2 excludes ONLY
# hard_protect — the exact "all soft_avoid" situation that froze the
# box on 2026-07-26 (THRASH-KILL: no eligible victim, all avoid_kill?)
# now STILL kills the largest-RSS non-hard_protect process instead of
# doing nothing. Prints "pid rss comm tier".
pick_cgroup_victim() {
  local procs="$1/cgroup.procs" p comm rss
  local best_pid="" best_rss=-1 best_comm=""
  local fb_pid="" fb_rss=-1 fb_comm=""
  [ -r "$procs" ] || return 1
  while read -r p; do
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -le 1 ]; then continue; fi
    comm=$(cat "/proc/$p/comm" 2>/dev/null) || continue
    echo "$comm" | grep -Eq -- "$HARD_PROTECT" && continue
    rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$p/status" 2>/dev/null)
    [ -n "$rss" ] || continue
    # Fallback pool: any non-hard_protect process (covers soft_avoid too).
    if [ "$rss" -gt "$fb_rss" ]; then fb_rss="$rss"; fb_pid="$p"; fb_comm="$comm"; fi
    # Preferred pool: non-hard_protect AND non-soft_avoid.
    echo "$comm" | grep -Eq -- "$SOFT_AVOID" && continue
    if [ "$rss" -gt "$best_rss" ]; then best_rss="$rss"; best_pid="$p"; best_comm="$comm"; fi
  done < "$procs"
  if [ -n "$best_pid" ]; then
    echo "$best_pid $best_rss $best_comm preferred"
  elif [ -n "$fb_pid" ]; then
    echo "$fb_pid $fb_rss $fb_comm fallback-soft_avoid"
  fi
}

# Signal picker WITH ESCALATION (2026-07-10 v3 — root cause of the 13:06
# freeze). Graceful SIGTERM for node/claude so Claude Code can print its
# "claude --resume" hint; hard SIGKILL for everything else. CRITICAL FIX:
# a graceful SIGTERM that is IGNORED must ESCALATE. The 13:06 freeze was
# freeze-guard SIGTERM-ing the SAME claude pid (89831, comm=ld-linux) 20+
# times over 75s while it sat wedged in IO-stall (D-state) and never died
# — polite-forever with no teeth. Now: first offense = SIGTERM; if the
# SAME pid is still the offender on a later tick (already in TERMED) =
# SIGKILL. So a process that won't leave on request gets forced out within
# one interval. Match on FULL CMDLINE (claude runs via ld-linux, comm
# misses it). TERMED is a persistent cross-tick map (declared before the
# loop); dead pids are pruned there.
# Sets the global SIG (never echoes) and MUST be called directly, NOT via
# $(do_kill ...): command substitution runs in a subshell, so a TERMED[]
# mutation there would be lost and escalation would silently never fire
# (caught in testing 2026-07-10). Callers do:  do_kill "$pid" "$name"; sig=$SIG
do_kill() {
  local cmdline
  cmdline=$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || echo "$2")
  case "$cmdline" in
    *claude*|*node*)
      if [ -n "${TERMED[$1]:-}" ]; then
        kill -9 "$1" 2>/dev/null || true; unset "TERMED[$1]"; SIG=KILL-ESC
      else
        kill -TERM "$1" 2>/dev/null || true; TERMED[$1]=1; SIG=TERM
      fi ;;
    *) kill -9 "$1" 2>/dev/null || true; SIG=KILL ;;
  esac
  # ── RESET (2026-07-26) — after killing, restart the owning systemd
  # unit if this victim's comm is in RESET_UNITS, so daemons like
  # nix-daemon come back fresh instead of staying dead. An empty map
  # value means the process is a user-session process that systemd
  # --user / KDE respawns on its own — still logged, no restart command.
  # NOTE: RESET_UNITS lookup MUST be a regex scan, not an exact-key
  # lookup — /proc/<pid>/comm is truncated+wrapper-prefixed at runtime
  # (live values seen: ".plasmashell-wr", ".kwin_wayland-w", "nix" for a
  # runaway build), so exact `RESET_UNITS[$2]` misses them all. Match
  # HARD_PROTECT/SOFT_AVOID style: grep -Eq each key against $2.
  for _rk in "${!RESET_UNITS[@]}"; do
    # \b-anchored (2026-08-07): unanchored substring match let short keys
    # like "ld" (the linker) hit unrelated comms containing "ld" as a
    # substring — "thermald", "kthrotld" — firing a bogus nix-daemon
    # restart on every unrelated kill. \b still matches wrapper-prefixed
    # comms (".ld-wrapper") since "." is a non-word boundary.
    if printf '%s' "$2" | grep -Eq -- "\\b${_rk}\\b"; then
      _runit="${RESET_UNITS[$_rk]}"
      if [ -n "$_runit" ]; then
        sudo -n systemctl restart "$_runit" 2>/dev/null || true
        echo "[freeze-guard] RESET: $2 pid=$1 -> restart $_runit"
      else
        echo "[freeze-guard] RESET: $2 pid=$1 -> user-session respawn (no unit)"
      fi
      break
    fi
  done
}

# ── STATE PUBLISH (2026-08-07) — expose voter state for the KDE panel ──
# Writes /run/freeze-guard.json every tick so com.diegonmarcos.watchdog
# (mode=guard) can render live bars instead of the panel staying blind
# until a kill actually happens. Same atomic write-temp-then-mv
# discipline as my-konsole's watchdog.rs publish() — a widget polling on
# its own timer must never read a half-written file. World-readable
# (0644): the panel runs as uid 1000, freeze-guard runs as root-watchdog.
# All values/thresholds/sustain come from the SAME variables the voters
# above already use — nothing here recomputes or reimplements a trigger.
publish_guard_state() {
  local tmp=/run/freeze-guard.json.tmp
  local a_mem a_io a_cpu a_dio a_dmem a_thrash a_ws
  awk "BEGIN{exit !($mem+0>$MEM_LIMIT)}"        && a_mem=true    || a_mem=false
  awk "BEGIN{exit !($io+0>$IO_LIMIT)}"           && a_io=true     || a_io=false
  awk "BEGIN{exit !($cpu+0>$CPU_LIMIT)}"         && a_cpu=true    || a_cpu=false
  awk "BEGIN{exit !($sio+0>$SLICE_IO_LIMIT)}"    && a_dio=true    || a_dio=false
  awk "BEGIN{exit !($smem+0>$SLICE_MEM_LIMIT)}"  && a_dmem=true   || a_dmem=false
  [ "$thrash_secs" -ge "$THRASH_SUSTAIN" ] && a_thrash=true || a_thrash=false
  [ "$ws_secs" -ge "$WS_SUSTAIN" ]         && a_ws=true    || a_ws=false
  cat > "$tmp" <<EOF
{"ts":$(date +%s),"interval":$INTERVAL,"voters":[
{"id":"mem_psi_full","label":"mem PSI full","value":$mem,"threshold":$MEM_LIMIT,"sustain":0,"sustain_need":0,"armed":$a_mem},
{"id":"io_psi_full","label":"io PSI full","value":$io,"threshold":$IO_LIMIT,"sustain":0,"sustain_need":0,"armed":$a_io},
{"id":"cpu_psi_some","label":"cpu PSI some","value":$cpu,"threshold":$CPU_LIMIT,"sustain":0,"sustain_need":0,"armed":$a_cpu},
{"id":"desktop_io_psi_full","label":"desktop io PSI full","value":$sio,"threshold":$SLICE_IO_LIMIT,"sustain":0,"sustain_need":0,"armed":$a_dio},
{"id":"desktop_mem_psi_full","label":"desktop mem PSI full","value":$smem,"threshold":$SLICE_MEM_LIMIT,"sustain":0,"sustain_need":0,"armed":$a_dmem},
{"id":"mem_high_thrash","label":"mem.high thrash","value":$rate,"threshold":$HIGH_MAX,"sustain":$thrash_secs,"sustain_need":$THRASH_SUSTAIN,"armed":$a_thrash},
{"id":"write_storm","label":"write storm","value":$wmbps,"threshold":$WS_MBPS,"sustain":$ws_secs,"sustain_need":$WS_SUSTAIN,"armed":$a_ws}
]}
EOF
  chmod 0644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" /run/freeze-guard.json 2>/dev/null || true
}

# PSI IS THE ONLY KILL METRIC. No absolute CPU%/RSS/mem% triggers — those
# cause false kills (Claude died at PSI=0). We act ONLY on real kernel stall
# (PSI 'some'/'full' avg10 over limit); the victim is then RANKED by %cpu
# (cpu breach) or RSS (mem/io breach) — ranking is victim-selection, not the
# trigger. Graceful SIGTERM for node/claude via do_kill.
echo "[freeze-guard] online as $(id -un); PSI trigger — cpuPSI(some)>$CPU_LIMIT | memPSI(full)>$MEM_LIMIT | ioPSI(full)>$IO_LIMIT; THRASH trigger — memory.high >$HIGH_MAX/s for ${THRASH_SUSTAIN}s on $THRASH_CG; max $MAX_KILLS kills/tick"
prev_high=""; thrash_secs=0; ws_secs=0; PREV_WSEC=""; rate=0
declare -A TERMED    # pids already SIGTERM'd once — escalate to SIGKILL on recurrence
declare -A PREV_WB   # per-pid write_bytes for the write-storm voter's delta
while :; do
  # Prune maps: drop pids that already died (unbounded-growth guard).
  for _p in "${!TERMED[@]}"; do [ -d "/proc/$_p" ] || unset "TERMED[$_p]"; done
  for _p in "${!PREV_WB[@]}"; do [ -d "/proc/$_p" ] || unset "PREV_WB[$_p]"; done

  cpu=$(psi_avg10 cpu some);    cpu=${cpu:-0}
  mem=$(psi_avg10 memory full); mem=${mem:-0}
  io=$(psi_avg10 io full);      io=${io:-0}

  # ── VOTER: write-storm (v3.2) — LEADING indicator PSI misses ──────────
  # A write burst fills dirty page cache instantly (no stall → PSI flat);
  # the freeze hits later when dirty pages force synchronous writeback.
  # Watch the write RATE + dirty backlog directly and kill the top writer
  # BEFORE the stall. do_kill/pick_top_writer skip kthreads + essentials.
  wmbps=$(disk_write_mbps)
  dmb=$(dirty_mb); dmb=${dmb:-0}
  if [ "$wmbps" -gt "$WS_MBPS" ] || [ "$dmb" -gt "$WS_DIRTY_MB" ]; then
    ws_secs=$(( ws_secs + INTERVAL ))
    echo "[freeze-guard] WRITE-STORM ${wmbps}MB/s (>$WS_MBPS) dirty=${dmb}MB (>$WS_DIRTY_MB) sustained ${ws_secs}s/${WS_SUSTAIN}s"
    if [ "$ws_secs" -ge "$WS_SUSTAIN" ]; then
      read -r wpid wmb wcomm <<< "$(pick_top_writer)"
      if [ -n "$wpid" ] && [ "$wpid" -gt 1 ] 2>/dev/null; then
        do_kill "$wpid" "$wcomm"; wsig=$SIG
        echo "[freeze-guard] WRITE-STORM-KILL → SIG$wsig top-writer pid=$wpid ${wmb}MB/tick ($wcomm)"
      else
        echo "[freeze-guard] WRITE-STORM: no eligible writer (all essential/kthread?)"
      fi
      ws_secs=0
    fi
  else
    ws_secs=0
  fi

  # ── VOTER: per-slice desktop starvation (v3.1) — the 15:29 root cause ──
  # The desktop froze with user.slice io.pressure=96%/56% while GLOBAL io
  # was 0.14% — a bulk writer was hogging the NVMe queue and starving the
  # compositor. The global voter below is blind to this. Read the DESKTOP
  # slice's OWN pressure; if IT is starved, the culprit is a hog ELSEWHERE
  # (workload/machine/system) — kill the biggest hog, never the desktop's
  # own stalled procs. EVERY evaluation over threshold logs.
  sio=$(psi_slice_avg10 "$WATCH_CG" io full);     sio=${sio:-0}
  smem=$(psi_slice_avg10 "$WATCH_CG" memory full); smem=${smem:-0}
  if awk "BEGIN { exit !($sio+0 > $SLICE_IO_LIMIT || $smem+0 > $SLICE_MEM_LIMIT) }"; then
    read -r hpid hrss hcomm <<< "$(pick_hog_victim)"
    if [ -n "$hpid" ] && [ "$hpid" -gt 1 ] 2>/dev/null; then
      do_kill "$hpid" "$hcomm"; hsig=$SIG
      echo "[freeze-guard] DESKTOP-STARVED sliceIO=$sio sliceMEM=$smem (global io=$io) → SIG$hsig hog pid=$hpid rss=${hrss}kB ($hcomm)"
    else
      echo "[freeze-guard] DESKTOP-STARVED sliceIO=$sio sliceMEM=$smem — no hog victim outside the desktop (all essential/kthread?)"
    fi
  fi

  # ── VOTER: memory.high thrash (PSI-invisible reclaim storm) ──────────
  # Watches the throttle counter itself, so it fires even when PSI stays
  # low (the exact 13:06 blind spot). EVERY evaluation logs (silence was
  # what made the last freeze undebuggable).
  cur_high=$(awk '$1=="high"{print $2}' "$THRASH_CG/memory.events" 2>/dev/null)
  cur_high=${cur_high:-0}
  if [ -n "$prev_high" ]; then
    rate=$(( (cur_high - prev_high) / (INTERVAL > 0 ? INTERVAL : 1) ))
    [ "$rate" -lt 0 ] && rate=0
    if [ "$rate" -gt "$HIGH_MAX" ]; then
      thrash_secs=$(( thrash_secs + INTERVAL ))
      echo "[freeze-guard] THRASH-WATCH memory.high rate=${rate}/s > $HIGH_MAX (sustained ${thrash_secs}s/${THRASH_SUSTAIN}s) on $THRASH_CG"
      if [ "$thrash_secs" -ge "$THRASH_SUSTAIN" ]; then
        read -r vpid vrss vcomm vtier <<< "$(pick_cgroup_victim "$THRASH_CG")"
        if [ -n "$vpid" ] && [ "$vpid" -gt 1 ] 2>/dev/null; then
          do_kill "$vpid" "$vcomm"; vsig=$SIG
          echo "[freeze-guard] THRASH-KILL memory.high ${rate}/s → SIG$vsig pid=$vpid rss=${vrss}kB ($vcomm) tier=$vtier in $THRASH_CG"
        else
          echo "[freeze-guard] THRASH-KILL: no eligible victim in $THRASH_CG (all hard_protect?) — cannot act"
        fi
        thrash_secs=0
      fi
    else
      # decay, don't hard-reset (2026-08-07): real thrash is bursty and
      # dips below HIGH_MAX for a tick or two even mid-incident. A hard
      # reset to 0 here meant thrash_secs could never accumulate past a
      # couple seconds, so THRASH_SUSTAIN was in practice unreachable
      # and the relief kill never fired. Decay by one interval instead
      # so genuine sustained-but-bursty thrash still crosses the bar.
      thrash_secs=$(( thrash_secs > INTERVAL ? thrash_secs - INTERVAL : 0 ))
    fi
  fi
  prev_high="$cur_high"

  # Publish this tick's voter snapshot BEFORE the kill-escalation loop
  # below mutates cpu/mem/io — the panel should see the reading that
  # drove the decision, not the post-kill relief values.
  publish_guard_state

  # ── Pre-kill early warning (2026-08-11) ───────────────────────────────────
  # This guard went from silence straight to SIGKILL. PSI_LADDER_PCT are
  # alert-ONLY rungs, as percentages of each limit, crossed before anything is
  # killed — so an approaching freeze is visible while it can still be steered
  # by hand. Nothing here kills, ranks or signals; it only reports.
  #
  # Rate-limited by rung: interval_sec is 2, so an unthrottled alert would emit
  # 30 messages a minute and become noise nobody reads. Re-alerts only when the
  # highest crossed rung CHANGES, or after PSI_ALERT_REARM_SEC at the same rung.
  if [ -n "${PSI_LADDER_PCT:-}" ]; then
    _rung=0; _sig=""
    for _p in $PSI_LADDER_PCT; do
      if awk "BEGIN{exit !($mem+0 > $MEM_LIMIT*$_p/100)}"; then [ "$_p" -gt "$_rung" ] && { _rung=$_p; _sig="mem PSI ${mem} (kills at ${MEM_LIMIT})"; }; fi
      if awk "BEGIN{exit !($io+0  > $IO_LIMIT*$_p/100)}";  then [ "$_p" -gt "$_rung" ] && { _rung=$_p; _sig="io PSI ${io} (kills at ${IO_LIMIT})"; }; fi
      if awk "BEGIN{exit !($cpu+0 > $CPU_LIMIT*$_p/100)}"; then [ "$_p" -gt "$_rung" ] && { _rung=$_p; _sig="cpu PSI ${cpu} (kills at ${CPU_LIMIT})"; }; fi
    done
    _now=$(date +%s)
    if [ "$_rung" -gt 0 ] \
       && { [ "$_rung" != "${_psi_last_rung:-0}" ] || [ $(( _now - ${_psi_last_at:-0} )) -ge "${PSI_ALERT_REARM_SEC:-300}" ]; }; then
      _psi_last_rung="$_rung"; _psi_last_at="$_now"
      _msg="PRESSURE RISING (${_rung}% of the kill threshold): ${_sig}. Nothing has been killed yet — this is the warning before freeze-guard starts terminating processes."
      logger -t freeze-guard -p user.warning "$_msg"
      echo "[freeze-guard] PRE-KILL WARNING ${_rung}% — $_sig"
      curl -sS -H "Title: pressure rising ${_rung}% of kill threshold" -H "Priority: high" \
        -H "Tags: warning" -d "$_msg" "https://ntfy.sh/${PSI_NTFY_TOPIC:-diegonmarcos-infra}" 2>/dev/null || true
    fi
    # Reset once calm so the next climb alerts from the bottom rung again.
    [ "$_rung" -eq 0 ] && _psi_last_rung=0
  fi

  killed=""; n=0
  while [ "$n" -lt "$MAX_KILLS" ] && \
        awk "BEGIN { exit !($cpu+0 > $CPU_LIMIT || $mem+0 > $MEM_LIMIT || $io+0 > $IO_LIMIT) }"; do
    # Rank by %cpu when CPU is the breaching signal, else by RSS.
    if awk "BEGIN { exit !($cpu+0 > $CPU_LIMIT) }"; then key="pcpu"; else key="rss"; fi
    read -r pid metric name <<< "$(pick_victim "$key" "$killed")"
    if ! [[ "$pid" =~ ^[0-9]+$ ]] || [ "$pid" -le 1 ]; then break; fi
    do_kill "$pid" "$name"; sig=$SIG
    echo "[freeze-guard] FREEZE-RISK cpuPSI=$cpu memPSI=$mem ioPSI=$io → SIG$sig pid=$pid rank-by=$key metric=$metric ($name)"
    killed="$killed $pid"; n=$((n + 1))
    sleep 0.3   # let PSI reflect the kill before re-reading
    cpu=$(psi_avg10 cpu some);    cpu=${cpu:-0}
    mem=$(psi_avg10 memory full); mem=${mem:-0}
    io=$(psi_avg10 io full);      io=${io:-0}
  done
  [ "$n" -ge "$MAX_KILLS" ] && echo "[freeze-guard] hit max_kills_per_tick=$MAX_KILLS (cpuPSI=$cpu memPSI=$mem ioPSI=$io) — backing off one interval"
  sleep "$INTERVAL"
done
