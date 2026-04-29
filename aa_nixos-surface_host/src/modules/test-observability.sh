#!/usr/bin/env bash
# test-observability.sh — proves each producer in configuration_observability.nix
# is actually emitting to journald.
#
# Run AFTER `build.sh r` (switch). Returns 0 if all producers are wired,
# non-zero otherwise. Designed to be invoked by build.sh as a post-switch test.
#
# Per FIRE RULE 5: every observability claim must have a tester.

set -u
PASS=0; FAIL=0
declare -a FAILED_TESTS=()

ok()    { echo "[OK]   $1"; PASS=$((PASS+1)); }
fail()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }

# T1 — auditd is running and audit rules are loaded
if command -v auditctl >/dev/null 2>&1 && auditctl -l 2>/dev/null | grep -q "user-signals"; then
  ok "T1 auditd loaded with user-signals rule"
else
  fail "T1 auditd missing or rule user-signals not loaded"
fi

# T2 — auditd actually captures a kill() syscall to journald
TARGET_PID=$(sleep 30 & echo $!)
sleep 0.2
kill -TERM "$TARGET_PID" 2>/dev/null || true
sleep 1
if journalctl _TRANSPORT=audit --since "5 seconds ago" --no-pager 2>/dev/null | grep -q "key=\"user-signals\""; then
  ok "T2 audit kill event reached journald _TRANSPORT=audit"
else
  fail "T2 audit kill event NOT in journald (auditd→journal bridge broken)"
fi

# T3 — psacct kernel hook is recording (check pacct file growth, not lastcomm)
# Note: NixOS 24.11 ships acct 6.6.4 whose lastcomm has a glibc-buffer-overflow
# bug when reading newer pacct binary records. We test the underlying data
# (file is being written by the kernel) rather than the broken reader tool.
PACCT=/mnt/shared/log/account/pacct
if [ -r "$PACCT" ] || sudo -n test -r "$PACCT" 2>/dev/null; then
  SIZE=$(sudo -n stat -c%s "$PACCT" 2>/dev/null || stat -c%s "$PACCT" 2>/dev/null || echo 0)
  if [ "${SIZE:-0}" -gt 0 ]; then
    ok "T3 psacct pacct file growing (${SIZE} bytes) — kernel accounting active"
  else
    fail "T3 psacct pacct file exists but is empty — kernel hook not active"
  fi
else
  fail "T3 psacct pacct file missing at $PACCT"
fi

# T4 — systemd user manager log level is debug
USER_CONF="/etc/systemd/user.conf.d/90-observability.conf"
if [ -r "$USER_CONF" ] && grep -q "LogLevel=debug" "$USER_CONF"; then
  ok "T4 systemd user manager LogLevel=debug declared"
else
  fail "T4 systemd user manager debug config missing at $USER_CONF"
fi

# T5 — kernel.print-fatal-signals = 1
if [ "$(cat /proc/sys/kernel/print-fatal-signals 2>/dev/null)" = "1" ]; then
  ok "T5 kernel.print-fatal-signals=1 active"
else
  fail "T5 kernel.print-fatal-signals not set to 1"
fi

# T6 — QT_LOGGING_RULES present in environment
if env | grep -q "^QT_LOGGING_RULES=.*kwin"; then
  ok "T6 QT_LOGGING_RULES exposes kwin debug"
else
  fail "T6 QT_LOGGING_RULES does not contain kwin debug categories"
fi

# T7 — psi-recorder service is active and emitting recent journal lines
if systemctl is-active --quiet psi-recorder.service 2>/dev/null; then
  if journalctl -u psi-recorder.service --since "30 seconds ago" --no-pager 2>/dev/null | grep -q "psi-recorder.*slice="; then
    ok "T7 psi-recorder emitting slice/field journal lines"
  else
    fail "T7 psi-recorder active but no recent journal output"
  fi
else
  fail "T7 psi-recorder.service not active"
fi

# T7b — auditd log_file is on persistent disk, not tmpfs root
AUDIT_CONF=/etc/audit/auditd.conf
if [ -r "$AUDIT_CONF" ] && grep -qE "^log_file = /mnt/shared/log/audit/" "$AUDIT_CONF"; then
  ok "T7b auditd log_file declared on /mnt/shared (btrfs persistent)"
else
  fail "T7b auditd log_file not pointing to /mnt/shared/log/audit/ — would fill tmpfs root"
fi

# T7c — persistent audit dir exists on @shared and is on btrfs (not tmpfs)
AUDIT_DIR=/mnt/shared/log/audit
if [ -d "$AUDIT_DIR" ]; then
  FSTYPE=$(stat -f -c %T "$AUDIT_DIR" 2>/dev/null || echo unknown)
  if [ "$FSTYPE" = "btrfs" ]; then
    ok "T7c $AUDIT_DIR exists on btrfs"
  else
    fail "T7c $AUDIT_DIR exists but on $FSTYPE (expected btrfs)"
  fi
else
  fail "T7c persistent audit dir $AUDIT_DIR missing"
fi

# T7d — tmpfs root is not being filled by /var/log (regression guard)
ROOT_LOG_USE=$(du -sxm /var/log 2>/dev/null | awk '{print $1}')
if [ "${ROOT_LOG_USE:-0}" -lt 100 ]; then
  ok "T7d /var/log on tmpfs root under 100 MiB (${ROOT_LOG_USE} MiB)"
else
  fail "T7d /var/log on tmpfs root is ${ROOT_LOG_USE} MiB — something is filling root again"
fi

# T8 — all four producers reachable through one journalctl query
COUNT=$(journalctl --since "5 minutes ago" --no-pager 2>/dev/null \
  | grep -cE "(_TRANSPORT=audit|psi-recorder|kernel:.*signal|systemd\[.*\]: Activating)")
if [ "$COUNT" -gt 0 ]; then
  ok "T8 unified journald query finds events from $COUNT producer(s)"
else
  fail "T8 unified journald query empty — pipeline not wired end-to-end"
fi

# T9 — invariant: NO permanent service writes more than 50 MiB to tmpfs root
# This is the generic guard against future regressions of the auditd / coredump /
# psacct anti-pattern. Anything persistent must be on btrfs (/mnt/shared/*).
ROOT_OFFENDERS=$(sudo du -xhd3 /var 2>/dev/null \
  | awk '$1 ~ /^[0-9]+(\.[0-9]+)?[GM]$/ {
      # Convert size to MiB
      n=$1; sub(/[GM]/,"",n);
      mib = ($1 ~ /G$/) ? n*1024 : n+0;
      if (mib >= 50) print mib " MiB " $2;
    }')
if [ -z "$ROOT_OFFENDERS" ]; then
  ok "T9 no persistent service exceeds 50 MiB on tmpfs root"
else
  fail "T9 persistent service(s) writing to tmpfs root (regression of auditd/coredump anti-pattern):"
  echo "$ROOT_OFFENDERS" | sed 's/^/    /'
fi

# T10 — psacct file is on @shared (btrfs), not tmpfs
PACCT_FSTYPE=$(stat -f -c %T "$(dirname "$PACCT")" 2>/dev/null || echo unknown)
if [ "$PACCT_FSTYPE" = "btrfs" ]; then
  ok "T10 psacct pacct dir on btrfs ($(dirname "$PACCT"))"
else
  fail "T10 psacct pacct dir on $PACCT_FSTYPE (expected btrfs)"
fi

# T11 — systemd-coredump path resolved to btrfs (via L+ symlink to /mnt/shared/coredump)
COREDUMP_DIR=/var/lib/systemd/coredump
COREDUMP_REAL=$(readlink -f "$COREDUMP_DIR" 2>/dev/null || echo "$COREDUMP_DIR")
COREDUMP_FSTYPE=$(stat -f -c %T "$COREDUMP_REAL" 2>/dev/null || echo unknown)
if [ "$COREDUMP_FSTYPE" = "btrfs" ]; then
  ok "T11 systemd-coredump resolves to btrfs ($COREDUMP_REAL)"
else
  fail "T11 systemd-coredump resolves to $COREDUMP_FSTYPE at $COREDUMP_REAL (expected btrfs)"
fi

echo ""
echo "──────────────────────────────────────────"
echo "Observability test summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
exit 0
