#!/usr/bin/env bash
# Generated from programs/hm-auto-update.nix — do not edit by hand.
set -uo pipefail

# HAU_* env overrides let test-hm-auto-update.sh exercise this exact
# generated script with stub gh/skopeo/yad/systemd-run + an isolated
# state dir, instead of testing a hand-copied duplicate of the logic.
IMAGE="${HAU_IMAGE:-@image@}"
TAG="${HAU_TAG:-@tag@}"
BUILD_SH="${HAU_BUILD_SH:-@repoBuildSh@}"
DELAY="${HAU_DELAY:-@delaySeconds@}"
DIALOG_ENABLED="${HAU_DIALOG:-@dialogCenter@}"
NOTIFY_ENABLED="@notifySend@"
MIN_FREE_MB="${HAU_MIN_FREE_MB:-@minFreeMb@}"
SW_MEM_MAX="@switchMemoryMax@"
SW_SWAP_MAX="@switchSwapMax@"

command -v skopeo >/dev/null 2>&1 || { echo "hm-auto-update: skopeo missing, skipping check" >&2; exit 0; }
command -v gh >/dev/null 2>&1 || { echo "hm-auto-update: gh CLI missing, skipping check" >&2; exit 0; }

STATE_DIR="${HAU_STATE_DIR:-$HOME/.cache/hm-auto-update}"
mkdir -p "$STATE_DIR"
DIGEST_FILE="$STATE_DIR/last-digest"

TOKEN="$(gh auth token 2>/dev/null)" || { echo "hm-auto-update: gh not authenticated, skipping check" >&2; exit 0; }

NEW_DIGEST="$(skopeo inspect --format '{{.Digest}}' --creds "x:$TOKEN" "docker://$IMAGE:$TAG" 2>/dev/null)"
if [ -z "$NEW_DIGEST" ]; then
  echo "hm-auto-update: could not inspect $IMAGE:$TAG (unavailable or not yet pushed), skipping check" >&2
  exit 0
fi

if [ ! -f "$DIGEST_FILE" ]; then
  # First run — seed the baseline, don't trigger a switch for a digest
  # that (for all we know) is already what's active.
  echo "$NEW_DIGEST" > "$DIGEST_FILE"
  echo "hm-auto-update: seeded baseline digest $NEW_DIGEST" >&2
  exit 0
fi

OLD_DIGEST="$(cat "$DIGEST_FILE" 2>/dev/null || true)"
if [ "$NEW_DIGEST" = "$OLD_DIGEST" ]; then
  exit 0
fi

# ── RAM-headroom guard (2026-07-10) ─────────────────────────────────
# A new generation exists — but if the desktop is already memory-full,
# firing a ~GB pull now tips user-1000.slice into reclaim-thrash and
# freezes the box (exactly the 13:41 bootstrap freeze). DEFER: do NOT
# record the digest, so the very next poll retries once the box has
# headroom. This is the difference between "auto-update waits politely"
# and "auto-update freezes your desktop".
AVAIL_MB=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
AVAIL_MB="${AVAIL_MB:-0}"
if [ "$AVAIL_MB" -lt "$MIN_FREE_MB" ]; then
  echo "hm-auto-update: DEFERRING switch — only ${AVAIL_MB}MB free < ${MIN_FREE_MB}MB safe floor; will retry next poll (digest NOT recorded)" >&2
  exit 0
fi

# Record the new digest NOW: whether the user proceeds or skips, we must
# not re-prompt every poll for the SAME digest. A later, different digest
# will prompt afresh.
echo "$NEW_DIGEST" > "$DIGEST_FILE"
SHORT="${NEW_DIGEST#sha256:}"; SHORT="${SHORT:0:12}"

[ "$NOTIFY_ENABLED" = "1" ] && command -v notify-send >/dev/null 2>&1 && \
  notify-send -i software-update-available "Home-manager auto-update" \
    "New generation ($SHORT) — activating in ${DELAY}s. To stop mid-switch: hm-auto-update-cancel" || true

# ── Cancellable countdown gate ──────────────────────────────────────
# yad with --timeout draws a visible shrinking bar and auto-exits (70)
# when it lapses = "proceed by default". Buttons: Switch now (0) /
# Skip this build (1). Only an explicit Skip aborts; timeout, close, or
# "Switch now" all proceed (honours the fully-automatic intent, with an
# explicit opt-out). Headless (no DISPLAY/WAYLAND, no yad, or dialog
# disabled) proceeds after the countdown — NEVER blocks unattended.
DECISION="proceed"
if [ "$DIALOG_ENABLED" = "1" ] && command -v yad >/dev/null 2>&1 \
   && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
  # Hard backstop (DELAY+5) in case yad itself hangs; yad's own --timeout
  # drives the visible countdown and exits 70 when it lapses.
  timeout $((DELAY + 5)) \
    yad --title="Home-manager auto-update" --window-icon=software-update-available \
        --width=460 --center --on-top --borders=12 \
        --image=software-update-available \
        --text="<b>New home-manager generation available</b>\ndigest $SHORT\n\nActivating automatically in $DELAY second(s).\nThe switch runs incrementally (only changed layers) and\nshows a live progress window." \
        --timeout="$DELAY" --timeout-indicator=bottom \
        --button="Skip this build!process-stop:1" \
        --button="Switch now!system-software-update:0"
  rc=$?
  case "$rc" in
    1) DECISION="skip" ;;   # explicit Skip only
    *) DECISION="proceed" ;; # 0 (now), 70 (timeout), 252 (closed), etc.
  esac
else
  echo "hm-auto-update: no graphical dialog (headless/disabled) — proceeding after ${DELAY}s" >&2
  sleep "$DELAY"
fi

if [ "$DECISION" = "skip" ]; then
  echo "hm-auto-update: user skipped generation $SHORT (digest recorded; next change re-prompts)" >&2
  [ "$NOTIFY_ENABLED" = "1" ] && command -v notify-send >/dev/null 2>&1 && \
    notify-send -i process-stop "Home-manager auto-update" "Skipped generation $SHORT." || true
  exit 0
fi

echo "hm-auto-update: activating generation $SHORT via build.sh switch (bounded: mem<=$SW_MEM_MAX swap<=$SW_SWAP_MAX)" >&2
# Detached — survives this oneshot service's own lifetime. build.sh's
# own .switch.lock flock (cmd_switch_runner) makes this safe even if a
# manual switch is already in flight. `switch` is incremental-first.
# MEMORY-BOUNDED: the switch's own footprint (build.sh, zstd, nix-store
# import) is capped so it can't pile onto the full desktop; if it
# balloons, oomd/OOM sacrifices the SWITCH, never the compositor.
systemd-run --user --unit=hm-auto-switch --collect \
  -p MemoryHigh="$SW_MEM_MAX" -p MemoryMax="$SW_MEM_MAX" -p MemorySwapMax="$SW_SWAP_MAX" \
  "$BUILD_SH" switch
