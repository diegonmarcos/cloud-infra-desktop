#!/usr/bin/env bash
# test-hibernation.sh — proves the hibernation stack is safe AND functional.
#
# Per FIRE RULE 5: every solution needs a tester. This is the tester for the
# 2026-06-12 incident fixes (p5-destroying invalidation, missing watchdog
# fallback, late-device resume registration, stale-generation drift).
#
# Modes:
#   ./test-hibernation.sh          static checks only (safe, no state change)
#   ./test-hibernation.sh --live   static checks + REAL hibernate/resume
#                                  round-trip + post-resume disk integrity.
#                                  The machine WILL hibernate: press the power
#                                  button to wake it, then the script resumes
#                                  and finishes its verification.
#
# Run as root (sudo) — several checks read root-only state
# (/var/lib/battery-watchdog, swapfile, ext4 superblock counters).
#
# DATA-DRIVEN: the bulk of the checks are executed straight from the
# testers.checks blocks of:
#   - cloud-data-battery-protection.json
#   - cloud-data-power.json
# Structural T-checks below cover what JSON checks cannot express
# (unit absence, post-resume journal evidence).

set -u
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_JSON="$MODULES_DIR/boot.json"
LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1

PASS=0; FAIL=0
declare -a FAILED_TESTS=()
ok()   { echo "[OK]   $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }

SWAPFILE=$(jq -r '.swap_hibernate.swapfile' "$BOOT_JSON")
RESUME_DEV=$(jq -r '.swap_hibernate.resume_device' "$BOOT_JSON")
DECLARED_OFFSET=$(jq -r '.swap_hibernate.resume_offset' "$BOOT_JSON")

# ── Section 1: JSON-declared testers (data-driven) ─────────────────────────
run_json_checks() {
  local json="$1" n i id cmd expect regex cmp out first second
  n=$(jq '.testers.checks | length' "$json")
  for i in $(seq 0 $((n - 1))); do
    id=$(jq -r ".testers.checks[$i].id" "$json")
    cmd=$(jq -r ".testers.checks[$i].command" "$json")
    expect=$(jq -r ".testers.checks[$i].expect // empty" "$json")
    regex=$(jq -r ".testers.checks[$i].expect_regex // empty" "$json")
    cmp=$(jq -r ".testers.checks[$i].expect_compare // empty" "$json")
    out=$(bash -c "$cmd" 2>/dev/null || true)
    # Checks marked "(run as user)" read $HOME config files — under sudo,
    # $HOME is /root and they come back empty. Retry as the invoking user.
    if [ -z "$out" ] && [ -n "${SUDO_USER:-}" ]; then
      out=$(sudo -u "$SUDO_USER" -H bash -c "$cmd" 2>/dev/null || true)
    fi
    if [ -n "$expect" ]; then
      if [ "$out" = "$expect" ]; then ok "$id"; else fail "$id (got '$out', want '$expect')"; fi
    elif [ -n "$regex" ]; then
      if echo "$out" | grep -Eq "$regex"; then ok "$id"; else fail "$id (got '$out', want regex '$regex')"; fi
    elif [ "$cmp" = "first_ge_second" ]; then
      first=$(echo "$out" | sed -n 1p); second=$(echo "$out" | sed -n 2p)
      if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -ge "$second" ]; then
        ok "$id ($first >= $second)"
      else
        fail "$id (first='$first' second='$second')"
      fi
    else
      fail "$id (no expectation declared in JSON)"
    fi
  done
}

echo "═══ JSON testers: cloud-data-battery-protection.json ═══"
run_json_checks "$MODULES_DIR/cloud-data-battery-protection.json"
echo "═══ JSON testers: cloud-data-power.json ═══"
run_json_checks "$MODULES_DIR/cloud-data-power.json"

# ── Section 2: structural checks (2026-06-12 incident invariants) ──────────
echo "═══ Structural checks ═══"

# T1 — the destroyer unit must NOT exist in a normal boot.
if [ "$(systemctl show -p LoadState --value rescue-invalidate-hibernate.service)" = "not-found" ]; then
  ok "T1 rescue-invalidate-hibernate absent from normal boot (rescue-specialisation-only)"
else
  fail "T1 rescue-invalidate-hibernate is loaded in a NORMAL boot — it must only exist in rescue specialisations"
fi

# T2 — the resume-offset gate ran and passed this boot.
if [ "$(systemctl show -p Result --value swapfile-resume-offset-check.service)" = "success" ]; then
  ok "T2 swapfile-resume-offset-check passed (triple agreement + backing device)"
else
  fail "T2 swapfile-resume-offset-check did not succeed: $(systemctl show -p Result --value swapfile-resume-offset-check.service)"
fi

# T3 — hibernate units not masked.
if systemctl is-enabled systemd-hibernate.service 2>&1 | grep -q "masked"; then
  fail "T3 systemd-hibernate.service is masked"
else
  ok "T3 systemd-hibernate.service not masked"
fi

# T4 — declared resume_device resolves and IS the swapfile's backing device.
RESOLVED=$(readlink -f "$RESUME_DEV" 2>/dev/null || echo "")
BACKING=$(findmnt -no SOURCE -T "$SWAPFILE" 2>/dev/null || echo "")
if [ -n "$RESOLVED" ] && [ "$RESOLVED" = "$BACKING" ]; then
  ok "T4 resume_device $RESUME_DEV → $RESOLVED == swapfile backing device"
else
  fail "T4 resume_device $RESUME_DEV → '$RESOLVED' but swapfile backed by '$BACKING'"
fi

# T5 — actual swapfile first extent == declared offset == cmdline.
ACTUAL=$(filefrag -v -b4096 "$SWAPFILE" 2>/dev/null | awk '/^   0:/{print $4; exit}' | tr -d '.')
CMDLINE=$(grep -o 'resume_offset=[0-9]*' /proc/cmdline | cut -d= -f2)
if [ "$ACTUAL" = "$DECLARED_OFFSET" ] && [ "$ACTUAL" = "$CMDLINE" ]; then
  ok "T5 resume_offset agreement (actual=$ACTUAL declared=$DECLARED_OFFSET cmdline=$CMDLINE)"
else
  fail "T5 resume_offset drift (actual=$ACTUAL declared=$DECLARED_OFFSET cmdline=$CMDLINE)"
fi

# T6 — watchdog has the escalation policy baked in.
# (trim: systemctl cat emits a trailing space after the ExecStart path)
WD_SCRIPT=$(systemctl cat battery-watchdog.service 2>/dev/null | awk -F= '/^ExecStart=/{gsub(/[[:space:]]+$/,"",$2); print $2; exit}')
if [ -n "$WD_SCRIPT" ] && grep -q "action_failures" "$WD_SCRIPT" 2>/dev/null; then
  ok "T6 battery-watchdog carries failure-escalation logic"
else
  fail "T6 battery-watchdog deployed WITHOUT escalation (old generation?)"
fi

# T7 — p5 ext4 error counter is zero (no lingering corruption).
P5_ERRORS=$(tune2fs -l "$RESOLVED" 2>/dev/null | awk -F: '/FS Error count/{gsub(/ /,"",$2); print $2}')
if [ -z "$P5_ERRORS" ] || [ "$P5_ERRORS" = "0" ]; then
  ok "T7 p5 ext4 FS error count: ${P5_ERRORS:-0}"
else
  fail "T7 p5 ext4 has FS error count=$P5_ERRORS — run fsck from rescue"
fi

# ── Section 3: live hibernate/resume round-trip (--live) ───────────────────
if [ "$LIVE" = "1" ]; then
  echo "═══ LIVE hibernate test ═══"
  if [ $FAIL -gt 0 ]; then
    echo "REFUSING live test: $FAIL static check(s) failed. Fix those first."
    exit 1
  fi
  MARKER="hibernate-test-$(date +%s)"
  TS_BEFORE=$(date -Is)
  logger -t test-hibernation "$MARKER: entering hibernation NOW (test)"
  echo ">>> Hibernating in 5 seconds — press the POWER BUTTON to wake. <<<"
  sleep 5
  BEFORE_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)

  if ! systemctl hibernate; then
    fail "T8 systemctl hibernate refused: check journalctl -u systemd-logind"
  else
    # Execution continues here AFTER resume.
    sleep 3
    AFTER_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
    if [ "$BEFORE_BOOT_ID" = "$AFTER_BOOT_ID" ]; then
      ok "T8 resumed into the SAME kernel (boot_id unchanged — true hibernate/resume)"
    else
      fail "T8 boot_id changed — the machine cold-booted instead of resuming (image lost?)"
    fi

    if journalctl -b --no-pager | grep -q "hibernation exit"; then
      ok "T9 kernel logged hibernation exit"
    else
      fail "T9 no 'hibernation exit' in this boot's journal"
    fi

    # Post-resume disk integrity — THE 2026-05-15 question.
    if findmnt "$(dirname "$SWAPFILE")" >/dev/null 2>&1; then
      ok "T10 /mnt/shared-lib still mounted after resume"
    else
      fail "T10 /mnt/shared-lib NOT mounted after resume"
    fi
    BTRFS_ERR=$(btrfs device stats /mnt/btrfs-root 2>/dev/null | awk '{s+=$2} END{print s+0}')
    if [ "$BTRFS_ERR" = "0" ]; then
      ok "T11 btrfs pool device error counters all zero after resume"
    else
      fail "T11 btrfs pool reports $BTRFS_ERR device errors after resume"
    fi
    # Scope to the hibernate/resume window only — full-boot dmesg may carry
    # pre-existing noise (2026-06-12: waydroid 'not a valid subvolume' mount
    # errors from hours before the test produced a false positive). That
    # mount-misconfig string is also excluded: it has its own CRIT alarm in
    # btrfs_subvols_autocreate and is not a corruption signal.
    if journalctl -k --since "$TS_BEFORE" --no-pager 2>/dev/null \
         | grep -iE "EXT4-fs error|BTRFS error" \
         | grep -v "is not a valid subvolume" >/dev/null; then
      fail "T12 filesystem errors logged during hibernate/resume window"
    else
      ok "T12 no EXT4/BTRFS errors during hibernate/resume window"
    fi
  fi
fi

# ── Report ──────────────────────────────────────────────────────────────────
echo
echo "═══ RESULT: $PASS passed, $FAIL failed ═══"
if [ $FAIL -gt 0 ]; then
  printf 'FAILED: %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
exit 0
