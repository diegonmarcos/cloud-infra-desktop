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
NTFY_TOPIC=$(jq -r '.actions.alert_ntfy.topic // "diegonmarcos-infra"' "$CONFIG_JSON")
NTFY_PRIORITY=$(jq -r '.emergency.ntfy_priority // "urgent"' "$CONFIG_JSON")

EMERG_WORST_PCT=0
# Reclaim-first gate: 1 = still full after reclaim (punish), 0 = self-healed
# (skip freeze/kill). Defaults to 1 so if recheck_gate is absent from the
# actions list the old always-punish behavior is preserved.
EMERG_STILL_FULL=1

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
      curl -sS -H "Title: disk-watchdog $mount $pct%" \
        -d "disk pressure: $mount at $pct%" \
        "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true ;;
    purge_tmp_worktrees)
      systemd-tmpfiles --clean --prefix=/tmp 2>/dev/null || true ;;
    purge_tmp_dotfiles)
      find /tmp -maxdepth 1 -name '.tmp*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true ;;
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
      curl -sS -H "Title: DISK EMERGENCY $mount $pct%" -H "Priority: ${NTFY_PRIORITY}" -H "Tags: rotating_light" \
        -d "$msg" "https://ntfy.sh/${NTFY_TOPIC}" 2>/dev/null || true ;;
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

# ── Per-mount loop — iterates the JSON array at RUNTIME (not code-generated).
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
  echo "[disk-watchdog] $MOUNT: ${USAGE}%"
  if [ "$USAGE" -ge "$EMERGENCY_PCT" ]; then
    echo "[disk-watchdog] EMERGENCY $MOUNT ${USAGE}% >= ${EMERGENCY_PCT}% — stop-the-bleeding"
    while read -r a; do run_action "$a" "$MOUNT" "$USAGE"; done < <(printf '%s\n' "$EMERGENCY_ACTIONS_JSON" | jq -r '.[]')
  elif [ "$USAGE" -ge "$CRITICAL_PCT" ]; then
    echo "[disk-watchdog] CRITICAL $MOUNT ${USAGE}% >= ${CRITICAL_PCT}%"
    while read -r a; do run_action "$a" "$MOUNT" "$USAGE"; done < <(printf '%s\n' "$ACTIONS_CRIT_JSON" | jq -r '.[]')
  elif [ "$USAGE" -ge "$WARN_PCT" ]; then
    echo "[disk-watchdog] WARN $MOUNT ${USAGE}% >= ${WARN_PCT}%"
    while read -r a; do run_action "$a" "$MOUNT" "$USAGE"; done < <(printf '%s\n' "$ACTIONS_WARN_JSON" | jq -r '.[]')
  fi
done < <(jq -r '.watches.mounts[]? | [.mount, .warn_pct, .critical_pct, (.actions_on_warn // [] | tojson), (.actions_on_critical // [] | tojson)] | @tsv' "$CONFIG_JSON")
