# kwin-crash-watchdog — switch to TTY on repeated KWin crashes
#
# Extracted from configuration_fallback.nix
# (systemd.user.services."kwin-crash-watchdog".serviceConfig.ExecStart).
#
# Runtime-data-driven: the crash window, the threshold, the watched unit and
# the rescue VT are read from /etc/cloud-data/kwin-crash-watchdog.json via jq
# at RUNTIME rather than being interpolated by Nix into this body. Real
# binary paths arrive via writeShellApplication runtimeEnv
# (JOURNALCTL_BIN / CHVT_BIN) — never as ${pkgs.foo} strings here.
#
# Fail-loud: this is a background systemd watchdog, not a wrapper around a
# user-facing command, so a missing/corrupt config must surface as a unit
# failure (logger + exit 1) rather than silently degrading into a watchdog
# that never fires. Restart=on-failure/RestartSec=10 stay Nix-side.
#
# No on-disk state file: all counters are in-memory only, exactly as before.
set -eu

JOURNALCTL="${KWIN_WATCHDOG_JOURNALCTL_BIN:?kwin-crash-watchdog: KWIN_WATCHDOG_JOURNALCTL_BIN not set}"
CHVT="${KWIN_WATCHDOG_CHVT_BIN:?kwin-crash-watchdog: KWIN_WATCHDOG_CHVT_BIN not set}"
CONFIG_JSON="${KWIN_WATCHDOG_CONFIG_JSON:-/etc/cloud-data/kwin-crash-watchdog.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t kwin-crash-watchdog -p user.err "$CONFIG_JSON missing or unreadable"
  exit 1
fi

WINDOW="$(jq -r '.window_seconds' "$CONFIG_JSON")"
THRESHOLD="$(jq -r '.crash_threshold' "$CONFIG_JSON")"
WATCH_UNIT="$(jq -r '.watch_unit' "$CONFIG_JSON")"
RESCUE_VT="$(jq -r '.rescue_vt' "$CONFIG_JSON")"

CRASH_COUNT=0
LAST_RESET=$(date +%s)

# Monitor KWin via systemd user journal
"$JOURNALCTL" --user -u "$WATCH_UNIT" -f --no-tail -o cat | while read -r line; do
  NOW=$(date +%s)

  # Reset counter if window expired
  if [ $((NOW - LAST_RESET)) -ge "$WINDOW" ]; then
    CRASH_COUNT=0
    LAST_RESET=$NOW
  fi

  # Detect crash indicators
  case "$line" in
    *"terminated"*|*"crash"*|*"SEGV"*|*"signal 11"*|*"Compositor crashed"*)
      CRASH_COUNT=$((CRASH_COUNT + 1))
      echo "[kwin-watchdog] KWin crash detected ($CRASH_COUNT/$THRESHOLD in ${WINDOW}s window)"

      if [ "$CRASH_COUNT" -ge "$THRESHOLD" ]; then
        echo "[kwin-watchdog] THRESHOLD REACHED — switching to TTY${RESCUE_VT}"
        "$CHVT" "$RESCUE_VT" 2>/dev/null || true
        CRASH_COUNT=0
        LAST_RESET=$NOW
      fi
      ;;
  esac
done
