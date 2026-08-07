#!/usr/bin/env bash
# hibernate-prewarn.sh — logs intent to journal, broadcasts via wall, sends
# desktop notifications and a centered countdown dialog, then lets
# ExecStart (the real hibernate) proceed. See
# configuration_pre-hibernate-warning.nix for the ExecStartPre= wiring on
# systemd-hibernate.service.
#
# Fully runtime-data-driven: every knob (delay, channels, cancel command)
# is read at RUNTIME from POWER_JSON (/etc/cloud-data/power.json, the
# cloud-data-power.json `pre_hibernate_warning` block) via jq. Nothing is
# baked in by Nix interpolation.
set -u

POWER_JSON="${HIBERNATE_POWER_JSON:-/etc/cloud-data/power.json}"

# This script only runs when pre_hibernate_warning.enabled=true (gated
# Nix-side in ExecStartPre=), so a config it can no longer read here is a
# genuine loss of the UX countdown — but REFUSING to hibernate over a
# missing prewarn config would be worse than the missing feature (the
# preflight gate already covers correctness). Log loudly and fall through
# to a bare sleep with the hardcoded delay-less default rather than block
# hibernation entirely.
if [ ! -r "$POWER_JSON" ] || ! jq -e . "$POWER_JSON" >/dev/null 2>&1; then
  logger -t hibernate-prewarn -p user.err "hibernate-prewarn: POWER_JSON missing/unreadable/unparseable at $POWER_JSON — proceeding without the UX countdown"
  echo "[hibernate-prewarn] config missing/unreadable at $POWER_JSON — proceeding without countdown" >&2
  exit 0
fi

# delay_seconds is the canonical knob (owner wants a 30s gate, not minutes).
# Back-compat: fall back to delay_minutes*60 if only the old field exists.
DELAY_SEC=$(jq -r '.pre_hibernate_warning.delay_seconds // ((.pre_hibernate_warning.delay_minutes // 0) * 60)' "$POWER_JSON")
CANCEL_CMD=$(jq -r '.pre_hibernate_warning.cancel_command // "sudo systemctl stop systemd-hibernate.service"' "$POWER_JSON")
CH_JOURNAL=$(jq -r 'if (.pre_hibernate_warning.channels.journal // false) then "1" else "0" end' "$POWER_JSON")
CH_WALL=$(jq -r 'if (.pre_hibernate_warning.channels.wall // false) then "1" else "0" end' "$POWER_JSON")
CH_NOTIFY_SEND=$(jq -r 'if (.pre_hibernate_warning.channels.notify_send // false) then "1" else "0" end' "$POWER_JSON")
CH_DIALOG_CENTER=$(jq -r 'if (.pre_hibernate_warning.channels.dialog_center // false) then "1" else "0" end' "$POWER_JSON")

MSG="System will HIBERNATE in $DELAY_SEC second(s). To CANCEL run: $CANCEL_CMD"

if [ "$CH_JOURNAL" = "1" ]; then
  echo "[hibernate-prewarn] $MSG"
  logger -t hibernate-prewarn -p daemon.warning "$MSG" || true
fi

if [ "$CH_WALL" = "1" ]; then
  # Broadcast to every terminal (tty + pty) with the inline cancel command.
  echo "$MSG" | wall -n || true
fi

if [ "$CH_NOTIFY_SEND" = "1" ]; then
  for udir in /run/user/*; do
    [ -d "$udir" ] || continue
    uid=$(basename "$udir")
    user=$(awk -F: -v u="$uid" '$3==u{print $1; exit}' /etc/passwd) || continue
    [ -n "$user" ] || continue
    bus="$udir/bus"
    [ -S "$bus" ] || continue
    runuser -u "$user" -- env \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" XDG_RUNTIME_DIR="$udir" \
      notify-send \
        -u critical -t $((DELAY_SEC * 1000)) -a "Power" \
        "Hibernation in $DELAY_SEC second(s)" "$MSG" || true
  done
fi

# ───── centered DARK modal with a live countdown + copyable cancel CLI ─────
# notify-send (above) is only a corner toast; this yad dialog is the
# centered, dark-themed, attention-grabbing popup the owner asked for:
#   • --timeout + --timeout-indicator = a visible shrinking countdown bar
#   • GTK_THEME=Adwaita:dark           = dark mode
#   • <tt>…</tt> + --selectable-labels = the cancel command in monospace,
#                                        selectable to copy & paste
# It also serves as the countdown wait. yad exit codes:
#   "Hibernate now" → 0  → proceed immediately
#   "Cancel"        → 1  → abort hibernation (ExecStartPre exits 1)
#   timed out       → 70 → proceed (the countdown elapsed)
#   could not display → fast non-zero → fall through to plain sleep
GUI_TEXT="<span size=\"xx-large\" weight=\"bold\">⚠  Hibernation</span>

The session is about to be saved to disk and the machine powered off.

<b>To cancel from a terminal, copy &amp; paste:</b>
<tt><big>$CANCEL_CMD</big></tt>

<i>...or press 'Cancel (stay awake)' below.</i>"
DID_WAIT=0
if [ "$CH_DIALOG_CENTER" = "1" ]; then
  for udir in /run/user/*; do
    [ -d "$udir" ] || continue
    uid=$(basename "$udir")
    user=$(awk -F: -v u="$uid" '$3==u{print $1; exit}' /etc/passwd) || continue
    [ -n "$user" ] || continue
    bus="$udir/bus"
    [ -S "$bus" ] || continue
    # Discover the Wayland socket for this session (KDE Plasma 6 = wayland-0).
    # Plain glob rather than ls: shellcheck rejects parsing ls (SC2012), and a
    # non-matching glob stays literal, so the -e test below falls back cleanly.
    wl=wayland-0
    for cand in "$udir"/wayland-[0-9]; do
      if [ -e "$cand" ]; then
        wl=$(basename "$cand")
        break
      fi
    done
    start=$(date +%s)
    set +e
    # Hard backstop timeout (DELAY+5) in case yad itself hangs; yad's own
    # --timeout drives the visible countdown and exits 70 when it lapses.
    runuser -u "$user" -- env \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
      XDG_RUNTIME_DIR="$udir" \
      WAYLAND_DISPLAY="${wl:-wayland-0}" \
      GDK_BACKEND="wayland,x11" \
      GTK_THEME="Adwaita:dark" \
      GTK_APPLICATION_PREFER_DARK_THEME=1 \
      timeout $((DELAY_SEC + 5)) \
      yad \
        --title="Hibernation" \
        --window-icon=battery-caution --image=battery-caution \
        --text="$GUI_TEXT" --text-align=center --selectable-labels \
        --timeout="$DELAY_SEC" --timeout-indicator=bottom \
        --center --on-top --width=560 --borders=20 \
        --button="Cancel (stay awake)!process-stop:1" \
        --button="Hibernate now!system-suspend-hibernate:0"
    rc=$?
    set -e
    elapsed=$(( $(date +%s) - start ))
    if [ "$rc" = "1" ]; then
      logger -t hibernate-prewarn -p daemon.warning \
        "user $user CANCELLED hibernation via centered dialog"
      exit 1
    fi
    # Count this as the countdown wait only if the dialog really ran
    # (timed out=70, or a button=0) rather than failing to display.
    if [ "$elapsed" -ge 2 ] || [ "$rc" = "0" ] || [ "$rc" = "70" ]; then DID_WAIT=1; fi
    break
  done
fi

# Fallback wait when no centered dialog ran (headless / display unavailable
# / dialog_center off) — the toast + terminal broadcast still gave notice.
if [ "$DID_WAIT" = "0" ] && [ "$DELAY_SEC" -gt 0 ]; then
  sleep "$DELAY_SEC"
fi
