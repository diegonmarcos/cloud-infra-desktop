#!/usr/bin/env bash
# disk-watchdog.sh — per-mount + emergency disk-full defense.
#
# Fully runtime-data-driven: ALL thresholds, mounts, slice names, actions and
# percentages are read from CONFIG_JSON (/etc/cloud-data/disk-protection.json)
# via jq. Nothing is baked in by Nix. See configuration_system-protection-disk.nix
# for how this script is wired (writeShellApplication + environment.etc deploy
# of the JSON) and cloud-data-disk-protection.json for the config + rationale.
#
# Built via pkgs.writeShellApplication — runtimeInputs supplies findmnt, df,
# jq, curl, logger, wall, systemctl, systemd-tmpfiles, find, docker (optional,
# checked with `command -v`), cargo-sweep (optional), nix, date, stat, touch.
set -u

CONFIG_JSON="${DISK_PROTECTION_JSON:-/etc/cloud-data/disk-protection.json}"

# Fail LOUDLY and safely if config is missing/unreadable/unparseable — a
# watchdog that reads no config must never conclude "everything is fine".
if [ ! -r "$CONFIG_JSON" ]; then
  logger -t disk-emergency -p user.err "disk-watchdog: CONFIG MISSING/UNREADABLE at $CONFIG_JSON — refusing to run with no thresholds"
  echo "[disk-watchdog] FATAL: config missing/unreadable at $CONFIG_JSON" >&2
  exit 1
fi
if ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t disk-emergency -p user.err "disk-watchdog: CONFIG UNPARSEABLE at $CONFIG_JSON — refusing to run with no thresholds"
  echo "[disk-watchdog] FATAL: config unparseable at $CONFIG_JSON" >&2
  exit 1
fi

# ── Emergency (stop-the-bleeding) tier — global, above every per-mount critical.
EMERGENCY_ACTIONS_JSON=$(jq -c '.emergency.actions // []' "$CONFIG_JSON")
# Disabled (no actions) → threshold 101 can never fire, so the chain falls
# straight through to critical/warn. Enabled → fires at emergency.pct (95).
if [ "$EMERGENCY_ACTIONS_JSON" = "[]" ]; then
  EMERGENCY_PCT=101
else
  EMERGENCY_PCT=$(jq -r '.emergency.pct // 95' "$CONFIG_JSON")
fi
KILL_SLICES=$(jq -r '(.emergency.kill_slices // []) | join(" ")' "$CONFIG_JSON")
FREEZE_SLICES=$(jq -r '(.emergency.freeze_slices // []) | join(" ")' "$CONFIG_JSON")
PROTECTED_SLICES=$(jq -r '(.emergency.protected_slices // []) | join(" ")' "$CONFIG_JSON")
COOLDOWN_MIN=$(jq -r '.emergency.cooldown_minutes // 0' "$CONFIG_JSON")
# Fill level above which COOLDOWN_MIN is ignored entirely. Defaults to 99
# rather than 100 because a volume reporting 100% is already refusing
# writes — the point is to act while there is still a sliver left.
NO_MERCY_PCT=$(jq -r '.emergency.no_mercy_pct // 99' "$CONFIG_JSON")
# Alert-only rungs below emergency.pct. Space-separated for the shell loop in
# escalate(). Empty list = no early warning, i.e. the old cliff-edge behaviour.
EMERG_LADDER_PCT=$(jq -r '(.emergency.alert_ladder_pct // []) | join(" ")' "$CONFIG_JSON")
NTFY_TOPIC=$(jq -r '.actions.alert_ntfy.topic // "diegonmarcos-infra"' "$CONFIG_JSON")
NTFY_PRIORITY=$(jq -r '.emergency.ntfy_priority // "urgent"' "$CONFIG_JSON")
# Seconds between ntfy posts FOR THE SAME KEY. See actions.alert_ntfy
# ._comment_min_interval: unthrottled, this guard posts once per mount per
# run and burns ntfy.sh's free daily quota before noon, after which every
# post returns HTTP 429 and the `|| true` eats it. 0 disables the gate.
NTFY_MIN_INTERVAL=$(jq -r '.actions.alert_ntfy.min_interval_sec // 3600' "$CONFIG_JSON")
DESKTOP_URGENCY=$(jq -r '.actions.alert_desktop.urgency // "critical"' "$CONFIG_JSON")
DESKTOP_ICON=$(jq -r '.actions.alert_desktop.icon // "drive-harddisk"' "$CONFIG_JSON")
# octocode code-index cache root + staleness cutoff (days) — data-driven per
# project rule, same mechanism as NTFY_TOPIC above. Defaults to "" (never a
# destructive glob) / 30 so a missing key cannot silently widen the cutoff.
OCTOCODE_PATH=$(jq -r '.actions.purge_octocode_stale.path // ""' "$CONFIG_JSON")
OCTOCODE_STALE_DAYS=$(jq -r '.actions.purge_octocode_stale.stale_days // 30' "$CONFIG_JSON")

EMERG_WORST_PCT=0
# Reclaim-first gate: 1 = still full after reclaim (punish), 0 = self-healed
# (skip freeze/kill). Defaults to 1 so if recheck_gate is absent from the
# actions list the old always-punish behavior is preserved.
EMERG_STILL_FULL=1

# True iff enough time has passed to post about "$1" again. Stamps on success,
# so a suppressed call never resets the clock. Keyed per mount+rung, because
# every mount here shares ONE pool: the posts were near-duplicates anyway.
ntfy_gate() {
  local key stamp now last
  if [ "${NTFY_MIN_INTERVAL:-0}" -le 0 ]; then return 0; fi
  key=$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')
  stamp="/run/disk-watchdog-ntfy-$key.stamp"
  now=$(date +%s)
  last=0
  if [ -f "$stamp" ]; then last=$(stat -c %Y "$stamp" 2>/dev/null || echo 0); fi
  if [ $(( now - last )) -lt "$NTFY_MIN_INTERVAL" ]; then return 1; fi
  touch "$stamp" 2>/dev/null || true
  return 0
}

# Pop a notification on every logged-in graphical session. The guard runs as
# root, and notify-send can only reach a user's session bus by address — so
# each session is re-entered as its own user with DBUS_SESSION_BUS_ADDRESS
# pointed at /run/user/<uid>/bus. Ungated on purpose: a desktop popup is
# idempotent (KDE collapses repeats), and this is the sink that was missing
# entirely while the pool sat at 98% for hours on 2026-09-03.
notify_desktop() {
  local title="$1" body="$2" uid who
  if ! command -v notify-send >/dev/null 2>&1; then return 0; fi
  loginctl list-users --no-legend 2>/dev/null | awk '$1 >= 1000 {print $1" "$2}' |
  while read -r uid who; do
    if [ ! -S "/run/user/$uid/bus" ]; then continue; fi
    runuser -u "$who" -- env \
      "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
      notify-send -u "$DESKTOP_URGENCY" -i "$DESKTOP_ICON" -- "$title" "$body" \
      2>/dev/null || true
  done
  return 0
}

# True iff a slice is in PROTECTED_SLICES — never freeze/kill these.
is_protected() {
  local q="$1" p
  for p in $PROTECTED_SLICES; do [ "$p" = "$q" ] && return 0; done
  return 1
}

run_action() {
  local action="$1" mount="${2:-?}" pct="${3:-?}"
  case "$action" in
    alert_ntfy)
      if ntfy_gate "warn-$mount"; then
        curl -sS -H "Title: disk-watchdog $mount $pct%" \
          -d "disk pressure: $mount at $pct%" \
          "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
      fi ;;
    alert_desktop)
      notify_desktop "Disk $pct% — $mount" \
        "disk-watchdog is reclaiming. Trace: journalctl -t disk-emergency -b" ;;
    purge_tmp_worktrees)
      systemd-tmpfiles --clean --prefix=/tmp 2>/dev/null || true ;;
    purge_tmp_dotfiles)
      find /tmp -maxdepth 1 -name '.tmp*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true ;;
    purge_tmp_gh_artifacts)
      # `gh run download` stages the artifact as /tmp/gh-artifact.<id>.zip and
      # leaks it if the process is killed — which is exactly what the emergency
      # tier below does when it freezes workload.slice, so this tier CREATES
      # this garbage. 2026-08-11: 4.0GB of these was the single largest
      # reclaimable item on the box while emergency reclaim reported freeing 0.
      # +30min so an in-flight download is never touched: the HM closure is
      # ~7GB and legitimately takes a while on home wifi.
      find /tmp -maxdepth 1 -name 'gh-artifact.*.zip' -mmin +30 -delete 2>/dev/null || true ;;
    purge_audit_old)
      # Bound the audit log dir even when high traffic outpaces tmpfiles cleanup.
      find /mnt/shared/log/audit -type f -mtime +3 -delete 2>/dev/null || true
      systemd-tmpfiles --clean --prefix=/mnt/shared/log/audit 2>/dev/null || true ;;
    cargo_sweep)
      if command -v cargo-sweep >/dev/null 2>&1; then
        cargo-sweep --time 30 /home/diego/.cargo/target 2>/dev/null || true
      fi ;;
    docker_prune_images)
      if command -v docker >/dev/null 2>&1; then
        docker image prune -f 2>/dev/null || true
      fi ;;
    docker_prune_builder)
      # Prune the buildkit BUILD CACHE — the 2026-07-10 freeze root cause:
      # ~16GB of build cache filled p5, untouchable by image/volume prune or
      # nix-gc, so reclaim was always insufficient → forced freeze. Build
      # cache is never referenced by a running container, so -af is safe.
      if command -v docker >/dev/null 2>&1; then
        docker builder prune -af 2>/dev/null || true
      fi ;;
    docker_prune_volumes_dangling)
      if command -v docker >/dev/null 2>&1; then
        docker volume prune -f 2>/dev/null || true
      fi ;;
    nix_gc_14d)
      nix-collect-garbage --delete-older-than 14d 2>/dev/null || true ;;
    nix_gc_emergency)
      # 14d is a no-op precisely when it is needed most. 2026-08-11, /nix at
      # 99%: the box had 5 system generations, the oldest 11 days old, so
      # `--delete-older-than 14d` matched nothing and reported "0 store paths
      # deleted, 0.00 MiB freed" -- twice -- and the ladder fell straight
      # through to FREEZING workload.slice. Reclaim-first only works if the
      # reclaim can actually reclaim.
      #
      # At >=95% keep only the CURRENT generation plus one rollback. Deleting
      # old generations never touches the running system: its closure is a live
      # GC root, so `switch-to-configuration` and the active boot entry are
      # unaffected. What is lost is the ability to roll back further than one
      # generation -- the correct trade at 99%, where the alternative is
      # freezing the user's work.
      nix-collect-garbage --delete-older-than 1d 2>/dev/null || true ;;
    purge_octocode_stale)
      # octocode (cloud-cgc-mcp's code-index cache) is REBUILDABLE per repo —
      # dropping a per-repo index dir only costs re-indexing time on next use.
      # 2026-08-11: 14G across 175 per-repo dirs, 70 of them (4.0GB) stale
      # >30d, was the single largest reclaimable item on the box at a moment
      # the emergency tier reported freeing 0 bytes and fell through to
      # freezing+SIGTERM of workload.slice.
      #
      # Guarded: OCTOCODE_PATH must be non-empty and an existing directory
      # before find ever runs, so a missing/unset config value is a no-op,
      # never a destructive glob. -mindepth 1 -maxdepth 1 -type d restricts
      # the match to DIRECT CHILD directories of the root only — the root
      # itself (mindepth 1) is never a match, and nothing below a child is
      # ever recursed into for matching (maxdepth 1).
      if [ -n "$OCTOCODE_PATH" ] && [ -d "$OCTOCODE_PATH" ]; then
        find "$OCTOCODE_PATH" -mindepth 1 -maxdepth 1 -type d -mtime "+${OCTOCODE_STALE_DAYS}" -exec rm -rf {} + 2>/dev/null || true
      fi ;;
    dev_store_gc)
      # GC the p5 dev-store chroot store (storeDir=/nix/store, root on p5). The
      # bc_flakes_dev-store profile gcroot pins the current toolchain.
      nix store gc --extra-experimental-features nix-command \
        --store 'local?root=/mnt/shared-lib/dev-store&store=/nix/store' 2>/dev/null || true ;;
    emergency_signal)
      # The unmissable "disk is full → stopping writes for cleanup" signal:
      # verbose journal (journalctl -t disk-emergency) + wall to every TTY + urgent ntfy.
      msg="DISK EMERGENCY: $mount at $pct% (>= ${EMERGENCY_PCT}%). RECLAIM-FIRST: pruning docker/nix/tmp now; if that frees enough, NOTHING is frozen or killed. Only if reclaim is insufficient: FREEZE [$FREEZE_SLICES] (pause, reversible) then SIGTERM [$KILL_SLICES] as last resort. Protected [$PROTECTED_SLICES] (ssh/wg/session/watchdog/freeze-guard) always preserved. Trace: journalctl -t disk-emergency -b"
      logger -t disk-emergency -p user.alert "$msg"
      echo "$msg"
      wall "disk-emergency: $mount $pct% full — non-system apps are being stopped to reclaim space. SAVE YOUR WORK." 2>/dev/null || true
      notify_desktop "DISK EMERGENCY — $mount $pct%" \
        "Non-system apps are being stopped to reclaim space. SAVE YOUR WORK."
      if ntfy_gate "emerg-$mount"; then
      curl -sS -H "Title: DISK EMERGENCY $mount $pct%" -H "Priority: ${NTFY_PRIORITY}" -H "Tags: rotating_light" \
        -d "$msg" "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
      fi ;;
    recheck_gate)
      # Re-read usage AFTER reclaim. If reclaim freed enough, self-heal: skip
      # freeze/kill entirely (the box is never disrupted). Else proceed to the
      # last-resort freeze/kill. Sets the global EMERG_STILL_FULL that
      # freeze_nonsystem/kill_nonsystem are gated on.
      local u
      u=$(df "$mount" --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
      if [[ "$u" =~ ^[0-9]+$ ]] && [ "$u" -lt "$EMERGENCY_PCT" ]; then
        EMERG_STILL_FULL=0
        logger -t disk-emergency -p user.info "RECLAIM SELF-HEALED $mount -> ${u}% (< ${EMERGENCY_PCT}%) — SKIPPING freeze/kill, box never disrupted"
        echo "[disk-watchdog] self-healed $mount ${u}% — no freeze/kill needed"
        curl -sS -H "Title: disk self-healed $mount ${u}%" -H "Priority: default" -H "Tags: white_check_mark" \
          -d "Reclaim freed enough on $mount (now ${u}%). Freeze/kill skipped — no session disruption." \
          "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
      else
        EMERG_STILL_FULL=1
        # Remember how bad it actually is. kill_nonsystem needs this to
        # decide whether the anti-spawn-storm cooldown may suppress it:
        # a cooldown that holds fire at 100% with zero reclaimed is not
        # protecting the box, it is guaranteeing ENOSPC.
        if [[ "$u" =~ ^[0-9]+$ ]] && [ "$u" -gt "${EMERG_WORST_PCT:-0}" ]; then
          EMERG_WORST_PCT="$u"
        fi
        logger -t disk-emergency -p user.warning "RECLAIM INSUFFICIENT $mount -> ${u}% (still >= ${EMERGENCY_PCT}%) — proceeding to last-resort freeze/kill"
      fi ;;
    freeze_nonsystem)
      # Gated: only if reclaim did NOT self-heal. cgroup-v2 freeze — survivor
      # writes halt INSTANTLY (paused, reversible, no data loss). Never freezes
      # a protected slice.
      [ "${EMERG_STILL_FULL:-1}" = "1" ] || { echo "[disk-watchdog] freeze skipped (self-healed)"; return 0; }
      for s in $FREEZE_SLICES; do
        if is_protected "$s"; then
          logger -t disk-emergency -p user.err "REFUSED to freeze protected slice $s"
          continue
        fi
        if systemctl freeze "$s" 2>/dev/null; then
          logger -t disk-emergency -p user.warning "FROZE $s -> its writes are halted for cleanup"
        fi
      done ;;
    kill_nonsystem)
      # Gated: only if reclaim did NOT self-heal. SIGTERM every process in the
      # non-system background slices. Never targets a protected slice.
      # Cooldown: don't re-SIGTERM the same slices within COOLDOWN_MIN — that
      # repeated kill every 5min was the 2026-07-08 spawn-storm. When on
      # cooldown the freeze + reclaim still ran; we just don't re-kill.
      [ "${EMERG_STILL_FULL:-1}" = "1" ] || { echo "[disk-watchdog] kill skipped (self-healed)"; return 0; }
      local stamp=/run/disk-emergency-kill.stamp
      # NO-MERCY FLOOR. Above this fill level the cooldown is void. The
      # cooldown's purpose is to stop a 5-minute SIGTERM loop from
      # spawn-storming (2026-07-08) — a real hazard at 95%, where the box
      # still works and there is time to retry. It is the wrong trade at
      # 99%+: reclaim already reported it freed nothing, so waiting out
      # 30 minutes cannot improve anything and simply hands the volume to
      # ENOSPC. Observed 2026-08-07: /nix, /mnt/shared and /mnt/shared-lib
      # all hit 100%, reclaim freed 0.00 MiB, and the kill was suppressed
      # with "cooldown: 8m < 30m" — the box filled anyway.
      if [ "${EMERG_WORST_PCT:-0}" -ge "${NO_MERCY_PCT}" ]; then
        logger -t disk-emergency -p user.err "NO-MERCY ${EMERG_WORST_PCT}% >= ${NO_MERCY_PCT}% — cooldown VOID, killing now"
      elif [ "${COOLDOWN_MIN:-0}" -gt 0 ] && [ -f "$stamp" ]; then
        local age=$(( ( $(date +%s) - $(stat -c %Y "$stamp") ) / 60 ))
        if [ "$age" -lt "${COOLDOWN_MIN}" ]; then
          logger -t disk-emergency -p user.warning "SIGTERM SUPPRESSED (cooldown: ${age}m < ${COOLDOWN_MIN}m) — froze + reclaimed, not re-killing to avoid spawn-storm"
          return 0
        fi
      fi
      touch "$stamp" 2>/dev/null || true
      for s in $KILL_SLICES; do
        if is_protected "$s"; then
          logger -t disk-emergency -p user.err "REFUSED to SIGTERM protected slice $s"
          continue
        fi
        if systemctl kill --kill-whom=all -s SIGTERM "$s" 2>/dev/null; then
          logger -t disk-emergency -p user.warning "SIGTERM -> $s (kill non-system writers)"
        fi
      done ;;
    thaw_nonsystem)
      # UNGATED and always last, so a transient spike or a run interrupted
      # between freeze and thaw never strands a slice frozen. No-op if already
      # thawed.
      for s in $FREEZE_SLICES; do
        if systemctl thaw "$s" 2>/dev/null; then
          logger -t disk-emergency -p user.info "THAWED $s -> resumed"
        fi
      done ;;
    *) echo "[disk-watchdog] unknown action: $action" ;;
  esac
}

# ── escalate — the ONE escalation path (warn -> critical -> emergency) shared
# by every usage source. Originally this three-tier if/elif chain was inlined
# once in the per-mount df loop below; it is now a function specifically so
# the btrfs-qgroup per-subvolume loop (further down) can feed IT THE SAME
# EMERG_WORST_PCT / NO_MERCY_PCT / freeze-then-kill machinery instead of
# duplicating it — a subvolume over its emergency threshold must reach the
# exact same freeze/kill path as the pool-wide emergency tier.
# Args: mount usage warn_pct critical_pct emerg_pct actions_warn_json actions_crit_json actions_emerg_json [label]
escalate() {
  local mount="$1" usage="$2" warn_pct="$3" critical_pct="$4" emerg_pct="$5"
  local actions_warn_json="$6" actions_crit_json="$7" actions_emerg_json="$8"
  local label="${9:-}" tag="" a
  [ -n "$label" ] && tag=" [$label]"
  echo "[disk-watchdog] ${mount}${tag}: ${usage}%"
  # ── Pre-emergency early warning (2026-08-11) ──────────────────────────────
  # Between critical and emergency there was NOTHING: the box went from a
  # routine CRITICAL line to freezing workload.slice with no escalating signal
  # in between, so the first thing the user ever noticed was the disruption
  # itself. EMERG_LADDER_PCT are alert-ONLY rungs below emerg_pct — they never
  # run a reclaim or freeze action, they just make the approach visible while
  # there is still time to act by hand. Highest crossed rung wins, so one pass
  # emits one message.
  if [ "$usage" -lt "$emerg_pct" ]; then
    local _hit=0 _p
    for _p in $EMERG_LADDER_PCT; do
      [ "$usage" -ge "$_p" ] && [ "$_p" -gt "$_hit" ] && _hit="$_p"
    done
    if [ "$_hit" -gt 0 ]; then
      local _m="DISK APPROACHING EMERGENCY: ${mount}${tag} at ${usage}% (emergency fires at ${emerg_pct}%). No reclaim, freeze or kill has run — this is the warning before that."
      logger -t disk-emergency -p user.warning "$_m"
      echo "[disk-watchdog] PRE-EMERGENCY ${mount}${tag} ${usage}% >= ${_hit}%"
      curl -sS -H "Title: disk ${mount} ${usage}% — nearing emergency" -H "Priority: high" \
        -H "Tags: warning" -d "$_m" "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true
    fi
  fi
  if [ "$usage" -ge "$emerg_pct" ]; then
    echo "[disk-watchdog] EMERGENCY ${mount}${tag} ${usage}% >= ${emerg_pct}% — stop-the-bleeding"
    while read -r a; do run_action "$a" "$mount" "$usage"; done < <(printf '%s\n' "$actions_emerg_json" | jq -r '.[]')
  elif [ "$usage" -ge "$critical_pct" ]; then
    echo "[disk-watchdog] CRITICAL ${mount}${tag} ${usage}% >= ${critical_pct}%"
    while read -r a; do run_action "$a" "$mount" "$usage"; done < <(printf '%s\n' "$actions_crit_json" | jq -r '.[]')
  elif [ "$usage" -ge "$warn_pct" ]; then
    echo "[disk-watchdog] WARN ${mount}${tag} ${usage}% >= ${warn_pct}%"
    while read -r a; do run_action "$a" "$mount" "$usage"; done < <(printf '%s\n' "$actions_warn_json" | jq -r '.[]')
  fi
}

# ── Per-mount loop — iterates the JSON array at RUNTIME (not code-generated).
# This is POOL-WIDE df accounting: every btrfs subvolume on the same pool
# reports the SAME used/avail here (df has no per-subvolume concept without
# qgroups) — see the btrfs-qgroup loop below for the per-subvolume answer.
while IFS=$'\t' read -r MOUNT WARN_PCT CRITICAL_PCT ACTIONS_WARN_JSON ACTIONS_CRIT_JSON; do
  [ -n "$MOUNT" ] || continue
  # `mountpoint -q` guard must NOT silently skip: log skipped mounts at
  # warning level, because a silent skip is exactly how /home went
  # unmonitored forever (see cloud-data-disk-protection.json /home/diego entry).
  if ! mountpoint -q "$MOUNT" 2>/dev/null; then
    logger -t disk-watchdog -p user.warning "disk-watchdog: $MOUNT is NOT a mountpoint — SKIPPED"
    echo "[disk-watchdog] $MOUNT: NOT MOUNTED — skipped"
    continue
  fi
  USAGE=$(df "$MOUNT" --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
  if ! [[ "$USAGE" =~ ^[0-9]+$ ]]; then
    echo "[disk-watchdog] $MOUNT: unreadable usage ('$USAGE') — skipped"
    continue
  fi
  escalate "$MOUNT" "$USAGE" "$WARN_PCT" "$CRITICAL_PCT" "$EMERGENCY_PCT" \
    "$ACTIONS_WARN_JSON" "$ACTIONS_CRIT_JSON" "$EMERGENCY_ACTIONS_JSON" ""
done < <(jq -r '.watches.mounts[]? | [.mount, .warn_pct, .critical_pct, (.actions_on_warn // [] | tojson), (.actions_on_critical // [] | tojson)] | @tsv' "$CONFIG_JSON")

# ── btrfs qgroup loop — PER-SUBVOLUME fill, only meaningful because qgroups
# exist (see cloud-data-disk-protection.json btrfs_qgroups._comment for why
# this is otherwise unrepresentable). Feeds the SAME escalate() function
# above, so a subvolume over ITS OWN emergency_pct reaches the exact same
# freeze/kill machinery as the pool-wide emergency tier — even if the pool
# as a whole is well under its own threshold. That is the entire point of
# this loop: it is additive granularity on top of the df loop, never a
# replacement for it.
QGROUPS_ENABLED=$(jq -r '.btrfs_qgroups.enabled // false' "$CONFIG_JSON")
if [ "$QGROUPS_ENABLED" = "true" ]; then
  FS_MOUNT=$(jq -r '.btrfs_qgroups.filesystem_mount // "/"' "$CONFIG_JSON")
  # Fixed, minimal action set for qgroup warn/critical — notify-only. The
  # destructive reclaim/freeze/kill actions live solely in EMERGENCY_ACTIONS_JSON
  # (global, already wired above) so a per-subvolume warn/critical never
  # duplicates or races the pool-wide reclaim list.
  QG_ACTIONS_WARN_JSON='["alert_ntfy"]'
  QG_ACTIONS_CRIT_JSON='["alert_ntfy"]'
  # Probe once: if `btrfs qgroup show` fails here (quotas not enabled, fs not
  # btrfs, permission denied, etc.) fall back cleanly to the df-based checks
  # already performed above — do NOT attempt per-subvolume evaluation with a
  # broken data source.
  if ! btrfs qgroup show --raw -f "$FS_MOUNT" >/dev/null 2>&1; then
    logger -t disk-watchdog -p user.warning "disk-watchdog: btrfs qgroup show failed on $FS_MOUNT (quotas not enabled / not btrfs?) — falling back to df-only per-mount checks"
    echo "[disk-watchdog] btrfs_qgroups enabled but 'btrfs qgroup show' failed on $FS_MOUNT — falling back to df-only checks"
  else
    POOL_TOTAL_BYTES=$(df --output=size -B1 "$FS_MOUNT" 2>/dev/null | tail -1 | tr -d ' ')
    [[ "$POOL_TOTAL_BYTES" =~ ^[0-9]+$ ]] || POOL_TOTAL_BYTES=0
    while IFS=$'\t' read -r SUBMOUNT SUBWARN SUBCRIT SUBEMERG; do
      [ -n "$SUBMOUNT" ] || continue
      if ! mountpoint -q "$SUBMOUNT" 2>/dev/null; then
        logger -t disk-watchdog -p user.warning "disk-watchdog: btrfs_qgroups $SUBMOUNT is NOT a mountpoint — SKIPPED"
        echo "[disk-watchdog] $SUBMOUNT: NOT MOUNTED — skipped (qgroup)"
        continue
      fi
      # Same parse bug btrfs-qgroup-setup.sh had (fixed 2026-08-11): `btrfs
      # subvolume show` TAB-indents every field, so "\tSubvolume ID: \t\t257"
      # never matches a /^Subvolume ID:/ anchor, and -F': ' leaves tabs in $2
      # that `tr -d ' '` does not strip. Unfixed, EVERY subvolume fell through to
      # "could not resolve subvolume ID — skipped (qgroup)", so enabling qgroups
      # bought no per-subvolume monitoring at all — the exact capability this
      # loop exists to provide.
      SUBVOLID=$(btrfs subvolume show "$SUBMOUNT" 2>/dev/null | awk '/Subvolume ID:/ {print $NF}' | tr -dc '0-9')
      if ! [[ "$SUBVOLID" =~ ^[0-9]+$ ]]; then
        echo "[disk-watchdog] $SUBMOUNT: could not resolve subvolume ID — skipped (qgroup)"
        continue
      fi
      # -re is REQUIRED, and its absence was a REAL bug, not cosmetic. Plain
      # `btrfs qgroup show --raw -f` prints only qgroupid/rfer/excl/path, so $4
      # was the PATH ('@home-diego'), never max_rfer. That string fails the
      # ^[0-9]+$ test below, so SUBMAXRFER was always empty and every subvolume
      # silently fell through to the pool-total branch — meaning the watchdog
      # IGNORED the kernel caps it had just been given and measured each
      # subvolume as a share of the whole 80G pool instead. /home/diego at
      # 21GiB reads 26% of the pool but 66% of its own 32GiB cap; the alert
      # ladder would have stayed asleep until far past the cap it exists to
      # enforce.
      QGROUP_ROW=$(btrfs qgroup show --raw -ref "$SUBMOUNT" 2>/dev/null | awk -v id="0/$SUBVOLID" '$1==id {print $2, $4}')
      if [ -z "$QGROUP_ROW" ]; then
        echo "[disk-watchdog] $SUBMOUNT: no qgroup row for 0/$SUBVOLID — skipped (qgroup)"
        continue
      fi
      SUBRFER=""
      SUBMAXRFER=""
      read -r SUBRFER SUBMAXRFER <<< "$QGROUP_ROW"
      if ! [[ "$SUBRFER" =~ ^[0-9]+$ ]]; then
        echo "[disk-watchdog] $SUBMOUNT: unreadable rfer ('$SUBRFER') — skipped (qgroup)"
        continue
      fi
      SUBPCT=""
      if [[ "$SUBMAXRFER" =~ ^[0-9]+$ ]] && [ "$SUBMAXRFER" -gt 0 ]; then
        # Enforced kernel limit set (limit_gib) — pct against that cap, since
        # that is the number the kernel itself will ENOSPC writes against.
        SUBPCT=$(( SUBRFER * 100 / SUBMAXRFER ))
      elif [ "$POOL_TOTAL_BYTES" -gt 0 ]; then
        # No hard limit configured (soft monitoring only) — pct against the
        # POOL's total size, i.e. "what share of the whole pool does this
        # ONE subvolume alone consume". This is exactly the number df cannot
        # give you per-subvolume, and is what makes '/home/diego at 95% while
        # the pool is at 60%' representable at all.
        SUBPCT=$(( SUBRFER * 100 / POOL_TOTAL_BYTES ))
      else
        echo "[disk-watchdog] $SUBMOUNT: no max_rfer and no pool total — skipped (qgroup)"
        continue
      fi
      escalate "$SUBMOUNT" "$SUBPCT" "$SUBWARN" "$SUBCRIT" "$SUBEMERG" \
        "$QG_ACTIONS_WARN_JSON" "$QG_ACTIONS_CRIT_JSON" "$EMERGENCY_ACTIONS_JSON" "qgroup"
    done < <(jq -r '.btrfs_qgroups.subvolumes[]? | [.mount, .warn_pct, .critical_pct, .emergency_pct] | @tsv' "$CONFIG_JSON")
  fi
fi
